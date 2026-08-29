//
//  NativeTextViewCoordinator+WritingTools.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  macOS 15+ Writing Tools integration: pauses styling during the session, re-syncs results on end, fixes child window position, and recovers from Apple's stale-accept-action bug after mid-session Cmd+Z.
//

import AppKit

extension NativeTextViewCoordinator {
    @available(macOS 15.0, *)
    public func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        // One session at a time. The snapshot taken at the FIRST `willBegin` is
        // the only baseline the end-of-session diff can publish against: it is
        // the last text the listener was told about. Re-snapshotting here would
        // silently swallow everything the running session had already changed,
        // because the second baseline already contains it. A controller drives
        // one view, so AppKit is the only thing that can nest these, and the
        // single `didEnd` that follows publishes both spans as one mutation.
        guard !isWritingToolsActive else {
            NSLog("MarkdownEngine: a second Writing Tools session began while one was "
                  + "still active; it is folded into the running session.")
            return
        }
        let sel = textView.selectedRange()
        isWritingToolsActive = true
        wtStartDocumentId = documentId
        wtSourceSnapshot = textView.string
        wtStartDocumentRevision = editorController?.documentRevision
        wtStartDocumentPublishedDelta = editorController?.documentPublishedDelta ?? 0
        wtStartDocumentLength = (textView.string as NSString).length
        wtChildWindow = nil
        wtInitialChildOrigin = nil
        wtInitialSelectionRange = sel.length > 0 ? sel : nil
        wtDetectedMode = .unknown
        wtUndoneDuringSession = false
        wtPostUndoSnapshot = nil
        observeUndoNotifications(for: textView.undoManager)
        scheduleChildWindowFix(textView: textView, attemptsRemaining: 20)
    }

    @available(macOS 15.0, *)
    public func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        guard isWritingToolsActive else { return }
        isWritingToolsActive = false
        let sourceBeforeWritingTools = wtSourceSnapshot
        let initialSelection = wtInitialSelectionRange
        let startRevision = wtStartDocumentRevision
        let startDocumentPublishedDelta = wtStartDocumentPublishedDelta
        let startDocumentLength = wtStartDocumentLength
        wtSourceSnapshot = nil
        wtStartDocumentRevision = nil
        wtStartDocumentPublishedDelta = 0
        wtStartDocumentLength = 0
        wtChildWindow = nil
        wtInitialChildOrigin = nil
        wtInitialSelectionRange = nil
        stopObservingUndoNotifications()

        // Doc switched mid-session — discard WT results, the new node already loaded.
        if wtStartDocumentId != nil && wtStartDocumentId != documentId {
            wtStartDocumentId = nil
            return
        }
        wtStartDocumentId = nil

        // Cmd+Z mid-session: Apple's stale accept-action corrupts text + contaminates attrs with 0.1pt marker font; the post-undo snapshot is the authoritative state.
        let sourceText: String
        if wtUndoneDuringSession, let snapshot = wtPostUndoSnapshot {
            sourceText = snapshot
        } else {
            sourceText = textView.string
        }
        wtUndoneDuringSession = false
        wtPostUndoSnapshot = nil

        let acceptedSelection = textView.selectedRange()
            .clamped(toLength: (sourceText as NSString).length)
        rebuildTextStorageAndStyle(textView, from: sourceText)
        lastSyncedText = sourceText
        textView.setSelectedRange(acceptedSelection)
        if let sourceBeforeWritingTools, sourceBeforeWritingTools != sourceText {
            let mutation: MarkdownTextMutation
            if let startRevision,
               let editorController,
               editorController.documentRevision != startRevision {
                mutation = rebasedWritingToolsMutation(
                    sourceBeforeWritingTools: sourceBeforeWritingTools,
                    sourceAfterWritingTools: sourceText,
                    initialSelection: initialSelection,
                    startRevision: startRevision,
                    startDocumentPublishedDelta: startDocumentPublishedDelta,
                    startDocumentLength: startDocumentLength,
                    controller: editorController
                )
            } else {
                let patch = MarkdownTextPatch.diff(
                    from: sourceBeforeWritingTools,
                    to: sourceText
                )
                mutation = MarkdownTextMutation(
                    range: patch.range,
                    replacement: patch.replacement
                )
            }
            publish(mutation)
        }
        scheduleBindingWriteBack(sourceText, from: textView)
    }

    private func rebasedWritingToolsMutation(
        sourceBeforeWritingTools: String,
        sourceAfterWritingTools: String,
        initialSelection: NSRange?,
        startRevision: UInt64,
        startDocumentPublishedDelta: Int,
        startDocumentLength: Int,
        controller: MarkdownEditorController
    ) -> MarkdownTextMutation {
        let listenerModelLength = startDocumentLength
            + controller.documentPublishedDelta
            - startDocumentPublishedDelta
        func fullReplacement(because reason: String) -> MarkdownTextMutation {
            NSLog("MarkdownEngine: Writing Tools published a full replacement because \(reason)")
            return MarkdownTextMutation(
                range: NSRange(location: 0, length: listenerModelLength),
                replacement: sourceAfterWritingTools
            )
        }

        guard let initialSelection,
              initialSelection.location >= 0,
              initialSelection.length > 0,
              NSMaxRange(initialSelection) <= (sourceBeforeWritingTools as NSString).length
        else {
            return fullReplacement(because: "the initial selection could not isolate the changed span")
        }
        guard let records = controller.documentMutationRecords(after: startRevision),
              !records.isEmpty
        else {
            return fullReplacement(because: "the concurrent mutation history was unavailable")
        }

        let foreignOnlyBaseline = NSMutableString(string: sourceBeforeWritingTools)
        var selection = initialSelection
        var externalDelta = 0
        for record in records {
            guard let mutation = record.mutation else {
                return fullReplacement(because: "a concurrent edit had no exact patch")
            }
            let replacementLength = (mutation.replacement as NSString).length
            let mutationDelta = record.mutationDelta
            let lengthBeforeMutation = record.documentLength - mutationDelta
            let writingToolsDelta = lengthBeforeMutation - startDocumentLength - externalDelta
            guard initialSelection.length + writingToolsDelta >= 0 else {
                return fullReplacement(because: "the selected span became invalid")
            }
            selection.length = initialSelection.length + writingToolsDelta
            if mutationOverlapsSelection(mutation.range, selection: selection) {
                return fullReplacement(because: "a concurrent edit overlapped the selected span")
            }

            let baselineLocation = NSMaxRange(mutation.range) <= selection.location
                ? mutation.range.location
                : mutation.range.location - writingToolsDelta
            let baselineRange = NSRange(
                location: baselineLocation,
                length: mutation.range.length
            )
            guard baselineLocation >= 0,
                  NSMaxRange(baselineRange) <= foreignOnlyBaseline.length
            else {
                return fullReplacement(because: "a concurrent edit could not be mapped to the listener's text")
            }
            foreignOnlyBaseline.replaceCharacters(
                in: baselineRange,
                with: mutation.replacement
            )
            selection = selection.adjusting(
                forReplacementOf: mutation.range,
                withLength: replacementLength
            )
            externalDelta += mutationDelta
        }

        let patch = MarkdownTextPatch.diff(
            from: foreignOnlyBaseline as String,
            to: sourceAfterWritingTools
        )
        return MarkdownTextMutation(
            range: patch.range,
            replacement: patch.replacement
        )
    }

    private func mutationOverlapsSelection(
        _ mutationRange: NSRange,
        selection: NSRange
    ) -> Bool {
        if mutationRange.length == 0 {
            return mutationRange.location >= selection.location
                && mutationRange.location <= NSMaxRange(selection)
        }
        return NSIntersectionRange(mutationRange, selection).length > 0
    }

    // MARK: - Child window (Done/Original panel) position fix

    private func scheduleChildWindowFix(textView: NSTextView, attemptsRemaining: Int) {
        guard attemptsRemaining > 0, isWritingToolsActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.isWritingToolsActive else { return }
            self.captureChildWindowIfNeeded(textView: textView)
            if self.wtChildWindow == nil {
                self.scheduleChildWindowFix(textView: textView, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func captureChildWindowIfNeeded(textView: NSTextView) {
        guard wtChildWindow == nil,
              let mainWindow = textView.window,
              let childWin = mainWindow.childWindows?.first(where: { $0.isVisible }) else { return }
        wtChildWindow = childWin
        wtInitialChildOrigin = childWin.frame.origin
    }

    // MARK: - Undo observer (captures post-undo snapshot for recovery)

    private func observeUndoNotifications(for undoManager: UndoManager?) {
        stopObservingUndoNotifications()
        guard let um = undoManager else { return }
        let center = NotificationCenter.default
        wtUndoObserverTokens = [
            center.addObserver(forName: .NSUndoManagerDidUndoChange, object: um, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let tv = self.textView, self.isWritingToolsActive else { return }
                    self.wtUndoneDuringSession = true
                    self.wtPostUndoSnapshot = tv.string
                }
            }
        ]
    }

    private func stopObservingUndoNotifications() {
        wtUndoObserverTokens.forEach(NotificationCenter.default.removeObserver(_:))
        wtUndoObserverTokens.removeAll()
    }

    func fixWritingToolsChildWindowIfNeeded(textView: NSTextView) {
        guard let childWin = wtChildWindow,
              let correctOrigin = wtInitialChildOrigin else { return }

        let frame = childWin.frame
        let needsFix = abs(frame.origin.x - correctOrigin.x) > 0.5 || abs(frame.origin.y - correctOrigin.y) > 0.5
        if needsFix {
            var fixed = frame
            fixed.origin = correctOrigin
            childWin.setFrame(fixed, display: false)
        }
    }
}

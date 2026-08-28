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
        let sel = textView.selectedRange()
        isWritingToolsActive = true
        wtStartDocumentId = documentId
        wtSourceSnapshot = textView.string
        wtStartDocumentRevision = editorController?.documentRevision
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
        let startDocumentLength = wtStartDocumentLength
        wtSourceSnapshot = nil
        wtStartDocumentRevision = nil
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
        let undoDuringSession: Bool
        if wtUndoneDuringSession, let snapshot = wtPostUndoSnapshot {
            sourceText = snapshot
            undoDuringSession = true
        } else {
            sourceText = textView.string
            undoDuringSession = false
        }
        wtUndoneDuringSession = false
        wtPostUndoSnapshot = nil

        // Binding is already equal to `sourceText` after undo so SwiftUI won't re-render — rebuild the textView directly.
        if undoDuringSession {
            rebuildTextStorageAndStyle(textView, from: sourceText)
        }
        if let sourceBeforeWritingTools, sourceBeforeWritingTools != sourceText {
            let mutation: MarkdownTextMutation?
            if let startRevision,
               let editorController,
               editorController.documentRevision != startRevision {
                mutation = rebasedWritingToolsMutation(
                    sourceBeforeWritingTools: sourceBeforeWritingTools,
                    sourceAfterWritingTools: sourceText,
                    initialSelection: initialSelection,
                    startRevision: startRevision,
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
            if let mutation {
                onTextMutation?(mutation)
            }
        }
        // Don't pre-set `lastSyncedText` — leaving it stale lets updateNSView do its
        // normal rebuild (restyle + re-measure) so the accepted WT result stays visible.
        DispatchQueue.main.async { [self] in
            text = sourceText
        }
    }

    private func rebasedWritingToolsMutation(
        sourceBeforeWritingTools: String,
        sourceAfterWritingTools: String,
        initialSelection: NSRange?,
        startRevision: UInt64,
        startDocumentLength: Int,
        controller: MarkdownEditorController
    ) -> MarkdownTextMutation? {
        guard let initialSelection,
              initialSelection.location >= 0,
              initialSelection.length > 0,
              NSMaxRange(initialSelection) <= (sourceBeforeWritingTools as NSString).length,
              let records = controller.documentMutationRecords(after: startRevision)
        else {
            NSLog("MarkdownEngine: Writing Tools mutation omitted because the changed span could not be isolated")
            return nil
        }

        var selection = initialSelection
        var externalDelta = 0
        for record in records {
            guard let mutation = record.mutation else {
                NSLog("MarkdownEngine: Writing Tools mutation omitted because a concurrent edit had no exact patch")
                return nil
            }
            let replacementLength = (mutation.replacement as NSString).length
            let mutationDelta = replacementLength - mutation.range.length
            let lengthBeforeMutation = record.documentLength - mutationDelta
            let writingToolsDelta = lengthBeforeMutation - startDocumentLength - externalDelta
            guard initialSelection.length + writingToolsDelta >= 0 else {
                NSLog("MarkdownEngine: Writing Tools mutation omitted because its selected span became invalid")
                return nil
            }
            selection.length = initialSelection.length + writingToolsDelta
            if mutationOverlapsSelection(mutation.range, selection: selection) {
                NSLog("MarkdownEngine: Writing Tools mutation omitted because a concurrent edit overlapped its selected span")
                return nil
            }
            selection = selection.adjusting(
                forReplacementOf: mutation.range,
                withLength: replacementLength
            )
            externalDelta += mutationDelta
        }

        let finalLength = (sourceAfterWritingTools as NSString).length
        let writingToolsDelta = finalLength - startDocumentLength - externalDelta
        guard initialSelection.length + writingToolsDelta >= 0 else {
            NSLog("MarkdownEngine: Writing Tools mutation omitted because its final selected span became invalid")
            return nil
        }
        selection.length = initialSelection.length + writingToolsDelta
        guard selection.location >= 0, NSMaxRange(selection) <= finalLength else {
            NSLog("MarkdownEngine: Writing Tools mutation omitted because its final selected span was out of bounds")
            return nil
        }

        let before = (sourceBeforeWritingTools as NSString).substring(with: initialSelection)
        let after = (sourceAfterWritingTools as NSString).substring(with: selection)
        guard before != after else { return nil }
        let patch = MarkdownTextPatch.diff(from: before, to: after)
        return MarkdownTextMutation(
            range: NSRange(
                location: selection.location + patch.range.location,
                length: patch.range.length
            ),
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

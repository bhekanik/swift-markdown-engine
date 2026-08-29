//
//  NativeTextViewCoordinator+Patch.swift
//  MarkdownEngine
//
//  The one primitive every non-keystroke text change goes through: an edit
//  applied to the live storage via `shouldChangeText → replaceCharacters →
//  didChangeText`, so the incremental restyle, the parse-state bookkeeping and
//  `onTextMutation` all see it exactly as they see a keystroke, unless the
//  caller already owns the incoming mutation (the external Binding path).
//

import AppKit

enum ExternalTextSpliceResult {
    case applied
    case declined
    case invalidated
}

extension NativeTextViewCoordinator {
    /// Apply one patch through the engine's own edit path.
    /// - Parameter publishesMutation: Pass `false` when the embedder already
    ///   supplied this edit through its Binding.
    /// - Returns: `false` when the range is out of bounds or the text view
    ///   refuses the change.
    func applyProgrammaticPatch(
        _ patch: MarkdownTextPatch,
        to textView: NSTextView,
        actionName: String? = nil,
        registersUndo: Bool = false,
        publishesMutation: Bool = true
    ) -> Bool {
        let sourceText = textView.string
        let length = (sourceText as NSString).length
        guard patch.range.location != NSNotFound, patch.range.location >= 0,
              patch.range.length >= 0, NSMaxRange(patch.range) <= length else { return false }
        let sourceController = editorController
        let sourceRevision = sourceController?.documentRevision

        // Close any open coalescing group BEFORE touching registration —
        // NSUndoManager rejects a disable that straddles an open group.
        textView.breakUndoCoalescing()
        let undoManager = textView.undoManager
        if !registersUndo { undoManager?.disableUndoRegistration() }
        defer { if !registersUndo { undoManager?.enableUndoRegistration() } }

        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }

        guard textView.shouldChangeText(in: patch.range, replacementString: patch.replacement) else {
            return false
        }
        guard textView.string == sourceText,
              editorController === sourceController,
              sourceController?.documentRevision == sourceRevision else {
            discardPendingTextProposal()
            return false
        }
        if !publishesMutation {
            pendingTextMutation = nil
        }
        textView.textStorage?.replaceCharacters(in: patch.range, with: patch.replacement)
        textView.didChangeText()
        if registersUndo, let actionName { undoManager?.setActionName(actionName) }
        textView.breakUndoCoalescing()
        return true
    }

    func applyProgrammaticPatches(
        _ patches: [MarkdownTextPatch],
        to textView: NSTextView,
        actionName: String? = nil,
        registersUndo: Bool = false
    ) -> Bool {
        let descending = patches.sorted { $0.range.location > $1.range.location }
        textView.breakUndoCoalescing()
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        for patch in descending {
            guard self.textView(
                textView,
                shouldChangeTextIn: patch.range,
                replacementString: patch.replacement
            ) else {
                discardPendingTextProposal()
                return false
            }
            discardPendingTextProposal()
        }

        let undoManager = textView.undoManager
        if registersUndo { undoManager?.beginUndoGrouping() }
        defer {
            if registersUndo {
                undoManager?.endUndoGrouping()
                if let actionName { undoManager?.setActionName(actionName) }
            }
            textView.breakUndoCoalescing()
        }

        beginSuppressingTextFinderInvalidation()
        defer { endSuppressingTextFinderInvalidation() }
        var selection = textView.selectedRange()
        for patch in descending {
            guard applyProgrammaticPatch(
                patch,
                to: textView,
                registersUndo: registersUndo
            ) else { return false }
            selection = selection.adjusting(
                forReplacementOf: patch.range,
                withLength: (patch.replacement as NSString).length
            )
        }
        textView.setSelectedRange(
            selection.clamped(toLength: (textView.string as NSString).length)
        )
        return true
    }

    /// Reconcile an externally changed `text` binding by splicing the single
    /// changed run instead of rebuilding the whole storage.
    ///
    /// `rebuildTextStorageAndStyle` assigns `textView.string`, and AppKit
    /// resets the selection to `{0, 0}` on that assignment — so a remote edit,
    /// a history navigation or a canonicalisation used to drop the reader's
    /// caret at the top of the document. A common-prefix/suffix diff turns
    /// almost all of those into one patch through `applyProgrammaticPatch`,
    /// which preserves the caret and restyles only the touched paragraphs.
    ///
    /// - Returns: Whether the patch applied, should fall back to a rebuild, or
    ///   became stale because a synchronous callback changed the document.
    func spliceExternalText(
        _ newText: String,
        in textView: NSTextView,
        publishesMutation: Bool = true
    ) -> ExternalTextSpliceResult {
        let currentDisplay = textView.string
        if !publishesMutation {
            synchronizeWithoutBindingWrite(newText)
        }
        guard currentDisplay != newText else { return .applied }
        var patch = MarkdownTextPatch.diff(from: currentDisplay, to: newText)

        // A change spanning nearly the whole document is a different document,
        // not an edit: the rebuild is both cheaper and the correct reset.
        let oldLength = (currentDisplay as NSString).length
        let touched = max(patch.range.length, (patch.replacement as NSString).length)
        guard oldLength == 0 || touched * 4 < oldLength * 3 else { return .declined }

        var selection = textView.selectedRange()
        let previousSyncedText = lastSyncedText
        let controllerBeforeEdit = editorController
        let revisionBeforeEdit = controllerBeforeEdit?.documentRevision
        var applied = applyProgrammaticPatch(
            patch,
            to: textView,
            publishesMutation: publishesMutation
        )
        let wasInvalidated = textView.string != currentDisplay
            || editorController !== controllerBeforeEdit
            || controllerBeforeEdit?.documentRevision != revisionBeforeEdit
        if !applied, wasInvalidated,
           let controller = controllerBeforeEdit,
           editorController === controller,
           let revisionBeforeEdit,
           let records = controller.documentMutationRecords(after: revisionBeforeEdit),
           !records.isEmpty,
           let rebasedPatch = rebased(patch, through: records) {
            patch = rebasedPatch
            selection = textView.selectedRange()
            applied = applyProgrammaticPatch(
                patch,
                to: textView,
                publishesMutation: publishesMutation
            )
        }
        guard applied else {
            if wasInvalidated {
                if !publishesMutation {
                    synchronizeWithoutBindingWrite(textView.string)
                } else {
                    lastSyncedText = textView.string
                }
                return .invalidated
            }
            lastSyncedText = previousSyncedText
            return .declined
        }
        let adjusted = selection
            .adjusting(forReplacementOf: patch.range,
                       withLength: (patch.replacement as NSString).length)
            .clamped(toLength: (textView.string as NSString).length)
        textView.setSelectedRange(adjusted)
        if !publishesMutation {
            synchronizeWithoutBindingWrite(textView.string)
        } else {
            lastSyncedText = textView.string
        }
        return .applied
    }

    func discardPendingTextProposal() {
        pendingTextMutation = nil
        pendingTextMutationStartLength = nil
        pendingEditedRange = nil
        pendingEditCount = 0
        pendingBacktickWindow = nil
        pendingExtFenceTouched = false
        pendingListStructureEdit = false
        pendingPreEditActiveTokenIndices = nil
    }

    private func rebased(
        _ patch: MarkdownTextPatch,
        through records: [MarkdownDocumentMutationRecord]
    ) -> MarkdownTextPatch? {
        var range = patch.range
        for record in records {
            guard let mutation = record.mutation else { return nil }
            guard NSMaxRange(mutation.range) < range.location
                    || NSMaxRange(range) < mutation.range.location else {
                return nil
            }
            range = range.adjusting(
                forReplacementOf: mutation.range,
                withLength: (mutation.replacement as NSString).length
            )
        }
        return MarkdownTextPatch(range: range, replacement: patch.replacement)
    }
}

extension NativeTextViewCoordinator {
    /// Drop everything memoised about the document's structure.
    ///
    /// The caches key on a generation counter and on the document's length,
    /// and neither moves when the storage under the view is REPLACED rather
    /// than edited — a controller swap points the view at a different
    /// document's storage, and the memoised parse of the old one would
    /// otherwise be styled onto the new text.
    func invalidateParseCache() {
        cachedParsedDocument = nil
        cachedParsedText = nil
        cachedParsedLength = -1
        cachedParseGeneration = .max
        parseGeneration &+= 1
        activeTokenMemo = nil
        parseState.invalidate()
        backtickCensusNeedsRescan = true
        pendingBacktickWindow = nil
    }
}

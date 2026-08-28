//
//  NativeTextViewCoordinator+Patch.swift
//  MarkdownEngine
//
//  The one primitive every non-keystroke text change goes through: an edit
//  applied to the live storage via `shouldChangeText → replaceCharacters →
//  didChangeText`, so the incremental restyle, the parse-state bookkeeping and
//  `onTextMutation` all see it exactly as they see a keystroke.
//

import AppKit

extension NativeTextViewCoordinator {
    /// Apply one patch through the engine's own edit path.
    /// - Returns: `false` when the range is out of bounds or the text view
    ///   refuses the change.
    func applyProgrammaticPatch(
        _ patch: MarkdownTextPatch,
        to textView: NSTextView,
        actionName: String? = nil,
        registersUndo: Bool = false
    ) -> Bool {
        let length = (textView.string as NSString).length
        guard patch.range.location != NSNotFound, patch.range.location >= 0,
              patch.range.length >= 0, NSMaxRange(patch.range) <= length else { return false }

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
        textView.textStorage?.replaceCharacters(in: patch.range, with: patch.replacement)
        textView.didChangeText()
        if registersUndo, let actionName { undoManager?.setActionName(actionName) }
        textView.breakUndoCoalescing()
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
    /// - Returns: `false` when the diff is most of the document; the caller
    ///   then falls back to the full rebuild.
    func spliceExternalText(_ newText: String, in textView: NSTextView) -> Bool {
        let currentDisplay = textView.string
        guard currentDisplay != newText else { return true }
        let patch = MarkdownTextPatch.diff(from: currentDisplay, to: newText)

        // A change spanning nearly the whole document is a different document,
        // not an edit: the rebuild is both cheaper and the correct reset.
        let oldLength = (currentDisplay as NSString).length
        let touched = max(patch.range.length, (patch.replacement as NSString).length)
        guard oldLength == 0 || touched * 4 < oldLength * 3 else { return false }

        let selection = textView.selectedRange()
        guard applyProgrammaticPatch(patch, to: textView) else { return false }
        let adjusted = selection
            .adjusting(forReplacementOf: patch.range,
                       withLength: (patch.replacement as NSString).length)
            .clamped(toLength: (textView.string as NSString).length)
        textView.setSelectedRange(adjusted)
        // textDidChange writes the binding back asynchronously; record the
        // synchronous truth now so the next update pass is not treated as
        // another external change.
        lastSyncedText = newText
        return true
    }
}

extension NativeTextViewCoordinator {
    /// Drop everything memoised about the document's structure.
    ///
    /// Called on the OTHER coordinators when one of them edits the shared
    /// storage. The caches key on a per-coordinator counter and on the
    /// document's length, and a same-length edit moves neither — so without
    /// this a second window keeps styling syntax that is no longer there.
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

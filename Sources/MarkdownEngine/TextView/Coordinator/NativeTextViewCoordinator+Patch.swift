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
    /// - Returns: `false` when the change cannot be expressed as one splice
    ///   (a wiki-link display transform is in effect, or the diff is most of
    ///   the document); the caller then falls back to the full rebuild.
    func spliceExternalText(_ newText: String, in textView: NSTextView) -> Bool {
        // Display must equal storage, or the diff is computed in the wrong
        // coordinate system. Raw mode is identity by definition; otherwise the
        // check is whether the wiki transform actually changed anything.
        let currentDisplay = textView.string
        guard configuration.rawSourceMode || lastComputedStorage == currentDisplay else { return false }
        guard currentDisplay != newText else { return true }

        let old = currentDisplay as NSString
        let new = newText as NSString
        var prefix = 0
        let maxPrefix = min(old.length, new.length)
        while prefix < maxPrefix, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        let maxSuffix = maxPrefix - prefix
        while suffix < maxSuffix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        let replacedLength = old.length - suffix - prefix
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - suffix - prefix))

        // A change spanning nearly the whole document is a different document,
        // not an edit: the rebuild is both cheaper and the correct reset.
        let touched = max(replacedLength, (replacement as NSString).length)
        guard old.length == 0 || touched * 4 < old.length * 3 else { return false }

        let selection = textView.selectedRange()
        let patch = MarkdownTextPatch(range: NSRange(location: prefix, length: replacedLength),
                                      replacement: replacement)
        guard applyProgrammaticPatch(patch, to: textView) else { return false }
        let adjusted = selection
            .adjusting(forReplacementOf: patch.range, withLength: (replacement as NSString).length)
            .clamped(toLength: (textView.string as NSString).length)
        textView.setSelectedRange(adjusted)
        // textDidChange writes the binding back asynchronously; record the
        // synchronous truth now so the next update pass is not treated as
        // another external change.
        lastSyncedText = newText
        return true
    }
}

//
//  MarkdownInputHandler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Handles Markdown typing shortcuts, like continuing lists.
import AppKit

enum MarkdownInputHandler {

    /// `codeTokens` (codeBlock + inlineCode, from the keystroke's existing
    /// parse) answers "is the caret in code?" without the O(doc) document
    /// scan the handler otherwise runs on every space/Enter/Tab.
    static func handleListInsertion(textView: NSTextView, affectedCharRange: NSRange, replacementString: String?, codeTokens: [MarkdownToken]? = nil) -> Bool {
        let isInsideCodeBlock = codeTokens.map {
            MarkdownDetection.isInsideCodeBlock(location: affectedCharRange.location, codeTokens: $0)
        }
        return MarkdownLists.handleInsertion(textView: textView, affectedCharRange: affectedCharRange,
                                             replacementString: replacementString, isInsideCodeBlock: isInsideCodeBlock)
    }

    private static func insertTextProgrammatically(_ textView: NSTextView, text: String, at range: NSRange, cursorAfter: Int) {
        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator {
            coord.isProgrammaticEdit = true
            // Replaces a suppressed keystroke that never applied — reset its
            // pending count so this edit registers as the cycle's single
            // tracked edit and textDidChange keeps the trusted fast paths.
            coord.pendingEditCount = 0
        }
        textView.insertText(text, replacementRange: range)
        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator {
            coord.isProgrammaticEdit = false
        }
        textView.setSelectedRange(NSRange(location: cursorAfter, length: 0))
    }

    /// Return inside a table row inserts `<br>` instead of splitting the row.
    ///
    /// A GFM row is ONE source line, so a bare newline tears the table in half.
    /// `<br>` is the format's only in-cell line break, and the renderer draws
    /// it as one. Covers ⇧↵ too: AppKit sends the same `insertNewline:` for
    /// both, so both arrive here as a `"\n"` replacement.
    ///
    /// Deliberately NOT handled at the token's outer edges — Return at the very
    /// start or end of the table stays a normal newline, which is the only way
    /// out of a table that reaches the end of the document.
    static func handleTableCellNewline(
        textView: NSTextView,
        affectedCharRange: NSRange,
        replacementString: String?,
        tableTokens: [MarkdownToken]
    ) -> Bool {
        guard replacementString == "\n" else { return false }
        let start = affectedCharRange.location
        let end = NSMaxRange(affectedCharRange)
        guard tableTokens.contains(where: { start > $0.range.location && end < NSMaxRange($0.range) })
        else { return false }

        let insertion = "<br>"
        insertTextProgrammatically(
            textView,
            text: insertion,
            at: affectedCharRange,
            cursorAfter: start + (insertion as NSString).length
        )
        return true
    }

}

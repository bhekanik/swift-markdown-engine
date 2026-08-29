//
//  MarkdownRendering.swift
//  MarkdownEngine
//
//  The styled document without a text view.
//

import AppKit

/// Produces the exact attributed string a `NativeTextViewWrapper` would show,
/// with no view, window or run loop involved.
///
/// The editor's rendering rules are otherwise only observable by putting a text
/// view on screen, which makes them awkward to test and impossible to reuse for
/// anything that is not the editor. This runs the same path the document
/// rebuild runs — base attributes, `MarkdownStyler.styleAttributes`, coalesce
/// into non-overlapping runs — so what it returns is what the reader sees.
public enum MarkdownRendering {

    /// The document as the reader sees it.
    ///
    /// - Parameters:
    ///   - markdown: The source. It is returned unchanged as the attributed
    ///     string's characters — markers are hidden by attributes, never
    ///     removed.
    ///   - caretLocation: Where the caret is, so that block's or run's markers
    ///     are revealed. `-1` (the default) reveals nothing, which is what a
    ///     reader who is not editing sees, and what a read-only presentation
    ///     always sees.
    ///   - selection: The full selected range, for the elements that reveal on
    ///     selection rather than on the caret (task checkboxes).
    ///   - configuration: Theme, marker sizes, extensions, raw-source mode.
    ///     `rawSourceMode` returns base attributes only, matching the editor.
    public static func attributedString(
        for markdown: String,
        fontName: String,
        fontSize: CGFloat,
        caretLocation: Int = -1,
        selection: NSRange? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> NSAttributedString {
        let ns = markdown as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let (baseFont, paragraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: nil,
            configuration: configuration
        )
        let baseAttributes = TextStylingService.makeBaseAttributes(
            font: baseFont, paragraphStyle: paragraphStyle, configuration: configuration)
        let built = NSMutableAttributedString(string: markdown)
        guard fullRange.length > 0 else { return built }
        built.setAttributes(baseAttributes, range: fullRange)
        guard !configuration.rawSourceMode else { return built }

        let tokens = MarkdownTokenizer.parseTokensViaAST(
            in: markdown, registry: configuration.extensionRegistry)
        let activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: selection ?? NSRange(location: max(caretLocation, 0), length: 0),
            tokens: tokens,
            in: ns,
            suppressed: caretLocation < 0
        )
        let ranges = MarkdownStyler.styleAttributes(
            text: markdown,
            fontName: fontName,
            fontSize: fontSize,
            caretLocation: caretLocation,
            selection: selection,
            activeTokenIndices: activeTokenIndices,
            precomputedTokens: tokens,
            configuration: configuration
        )
        // One setAttributes per non-overlapping run, exactly as the document
        // rebuild does — per-key addAttribute goes quadratic through
        // Foundation's weak attribute table on a large document.
        for (range, attributes) in MarkdownStyler.flattenedRuns(
            ranges, base: baseAttributes, documentLength: fullRange.length) {
            built.setAttributes(attributes, range: range)
        }
        return built
    }
}

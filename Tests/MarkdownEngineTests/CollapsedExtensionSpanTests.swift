//
//  CollapsedExtensionSpanTests.swift
//  MarkdownEngine
//
//  An inline extension can stand in for its whole span with a glyph — a
//  placeholder the writer drops mid-sentence (`<!--flag: town name-->` drawn
//  as a flag). The source stays in the text; it reveals only with the caret
//  strictly inside, so typing either side of the glyph never opens it.
//

import AppKit
import Testing
@testable import MarkdownEngine

private struct PlaceholderFlag: MarkdownExtension {
    static let glyph = NSImage(size: NSSize(width: 12, height: 11))
    var id: String { "flag" }
    var inline: InlineSyntax? {
        InlineSyntax(open: "<!--flag", close: "-->", parsesContent: false, requiresNonEmptyContent: false,
                     allowsCloseLeadInContent: true, precedesBuiltIns: true, collapsesToGlyph: true)
    }
    func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] { [:] }
    func html(childrenHTML: String) -> String { "" }
    func collapsedGlyph(theme: MarkdownEditorTheme, font: NSFont) -> NSImage? { Self.glyph }
}

@MainActor
@Suite("Collapsed extension spans")
struct CollapsedExtensionSpanTests {
    private let text = "Born in <!--flag: a mid-century town--> in 1920."
    private var flag: NSRange { (text as NSString).range(of: "<!--flag: a mid-century town-->") }

    private var configuration: MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.extensions = [PlaceholderFlag()]
        return configuration
    }

    private func render(caret: Int) -> NSAttributedString {
        MarkdownRendering.attributedString(
            for: text, fontName: "Helvetica", fontSize: 16, caretLocation: caret, configuration: configuration)
    }

    private func isCollapsed(_ styled: NSAttributedString) -> Bool {
        let glyph = styled.attribute(.renderedImage, at: flag.location, effectiveRange: nil) as? NSImage
        var allClear = true
        styled.enumerateAttribute(.foregroundColor, in: flag) { value, _, _ in
            if (value as? NSColor) != NSColor.clear { allClear = false }
        }
        return glyph === PlaceholderFlag.glyph && allClear
    }

    @Test("claims the HTML comment before the raw-HTML built-in, hyphens and all")
    func parsesAsExtension() {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text, registry: configuration.extensionRegistry)
        let span = tokens.first { $0.kind == .extensionSpan("flag") }
        #expect(span?.range == flag)
    }

    @Test("without precedence the comment stays the built-in's")
    func builtInWinsByDefault() {
        struct LateFlag: MarkdownExtension {
            var id: String { "flag" }
            var inline: InlineSyntax? {
                InlineSyntax(open: "<!--flag", close: "-->", parsesContent: false, allowsCloseLeadInContent: true)
            }
            func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] { [:] }
            func html(childrenHTML: String) -> String { "" }
        }
        let tokens = MarkdownTokenizer.parseTokensViaAST(
            in: text, registry: ExtensionRegistry(extensions: [LateFlag()]))
        #expect(!tokens.contains { $0.kind == .extensionSpan("flag") })
    }

    @Test("a lone closer lead-in still aborts spans that don't allow it")
    func loneLeadInAbortsByDefault() {
        struct Strict: MarkdownExtension {
            var id: String { "strict" }
            var inline: InlineSyntax? { InlineSyntax(open: "<!--flag", close: "-->", precedesBuiltIns: true) }
            func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] { [:] }
            func html(childrenHTML: String) -> String { "" }
        }
        let tokens = MarkdownTokenizer.parseTokensViaAST(
            in: text, registry: ExtensionRegistry(extensions: [Strict()]))
        #expect(!tokens.contains { $0.kind == .extensionSpan("strict") })
    }

    @Test("collapsed to its glyph when the caret is away, before or right after it", arguments: [-1, 0, 8, 39, 42])
    func collapsedOutside(caret: Int) {
        #expect(flag.location == 8 && NSMaxRange(flag) == 39)
        let styled = render(caret: caret)
        #expect(isCollapsed(styled))
        let kern = styled.attribute(.kern, at: flag.location, effectiveRange: nil) as? CGFloat ?? 0
        #expect(kern > 10, "the anchor reserves the glyph's width")
    }

    @Test("reveals its source with the caret strictly inside", arguments: [9, 20, 38])
    func revealedInside(caret: Int) {
        let styled = render(caret: caret)
        #expect(styled.attribute(.renderedImage, at: flag.location, effectiveRange: nil) == nil)
        let content = styled.attribute(.foregroundColor, at: flag.location + 12, effectiveRange: nil) as? NSColor
        #expect(content != NSColor.clear)
    }

    @Test("the active-token pass uses the same strict rule")
    func activeTokensAgree() {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text, registry: configuration.extensionRegistry)
        let index = tokens.firstIndex { $0.kind == .extensionSpan("flag") }!
        for (caret, expected) in [(8, false), (9, true), (38, true), (39, false)] {
            let active = MarkdownDetection.computeActiveTokenIndices(
                selectionRange: NSRange(location: caret, length: 0), tokens: tokens, in: text as NSString,
                collapsingExtensionIDs: configuration.collapsingExtensionIDs)
            #expect(active.contains(index) == expected, "caret \(caret)")
        }
    }

    @Test("never spell-checked")
    func noSpelling() {
        let styled = render(caret: 20)
        #expect(styled.attribute(.spellingState, at: flag.location + 12, effectiveRange: nil) as? Int == 0)
    }

    @Test("hidden from the visible text and from HTML")
    func hiddenFromProjections() {
        let projection = MarkdownTextProjection.make(markdown: text, configuration: configuration)
        #expect(projection.string == "Born in  in 1920.")
        let html = MarkdownHTMLRenderer.html(from: text, extensions: [PlaceholderFlag()])
        #expect(!html.contains("flag"))
        #expect(html.contains("Born in  in 1920."))
    }
}

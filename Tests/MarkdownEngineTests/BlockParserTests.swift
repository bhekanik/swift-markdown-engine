//
//  BlockParserTests.swift
//  MarkdownEngineTests
//
//  Phase 1 — test-first specification of the block-structure pass. Each test
//  pins an exact, tiling block decomposition (every UTF-16 unit covered once).
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 1 — block parser")
struct BlockParserTests {

    private func b(_ kind: BlockKind, _ location: Int, _ length: Int) -> Block {
        Block(kind: kind, range: NSRange(location: location, length: length))
    }

    /// Sanity: the parsed blocks must tile `text` with no gaps or overlaps.
    private func assertTiles(_ text: String) {
        let blocks = BlockParser.parse(text)
        let total = (text as NSString).length
        guard total > 0 else { return }
        var cursor = 0
        for block in blocks {
            #expect(block.range.location == cursor, "gap/overlap before \(block)")
            cursor = NSMaxRange(block.range)
        }
        #expect(cursor == total, "blocks do not cover the whole string")
    }

    @Test("single line is one paragraph")
    func singleParagraph() {
        #expect(BlockParser.parse("hello world") == [b(.paragraph, 0, 11)])
    }

    @Test("blank line separates blocks and the result tiles the whole string")
    func blankSeparates() {
        let text = "a\n\nb"
        #expect(BlockParser.parse(text) == [b(.paragraph, 0, 2), b(.blank, 2, 1), b(.paragraph, 3, 1)])
        assertTiles(text)
    }

    @Test("consecutive plain lines merge into one paragraph")
    func mergedParagraph() {
        #expect(BlockParser.parse("a\nb\nc") == [b(.paragraph, 0, 5)])
    }

    @Test("ATX heading is its own block")
    func heading() {
        let text = "# Title\n\nbody"
        #expect(BlockParser.parse(text) == [b(.heading, 0, 8), b(.blank, 8, 1), b(.paragraph, 9, 4)])
        assertTiles(text)
    }

    @Test("thematic break is its own block")
    func thematicBreak() {
        let text = "a\n\n---\n\nb"
        #expect(BlockParser.parse(text) == [
            b(.paragraph, 0, 2), b(.blank, 2, 1), b(.thematicBreak, 3, 4), b(.blank, 7, 1), b(.paragraph, 8, 1),
        ])
        assertTiles(text)
    }

    @Test("fenced code block is a single opaque block")
    func fencedCode() {
        #expect(BlockParser.parse("```\ncode\n```\n") == [b(.fencedCode, 0, 13)])
    }

    @Test("an unclosed fence stays literal text — blocks below are not swallowed")
    func unclosedFenceDoesNotSwallow() {
        // ```\n then a table, a thematic break, and a link
        // paragraph — none of them may end up inside a code block.
        let text = "```\n\n|a|b|\n|-|-|\n|1|2|\n\n---\n\n[l](u)"
        let blocks = BlockParser.parse(text)
        #expect(!blocks.contains { $0.kind == .fencedCode })
        #expect(blocks.contains { $0.kind == .table })
        #expect(blocks.contains { $0.kind == .thematicBreak })
        assertTiles(text)
    }

    @Test("an unclosed fence merges into the paragraph it starts")
    func unclosedFenceIsParagraph() {
        #expect(BlockParser.parse("```\n[l](u)") == [b(.paragraph, 0, 10)])
        #expect(BlockParser.parse("a\n```swift") == [b(.paragraph, 0, 10)])
    }

    @Test("a closed fence below an unclosed opener pairs with it")
    func fencePairing() {
        // The first ``` pairs with the next fence line — CommonMark pairing —
        // so this is one code block followed by a paragraph.
        let text = "```\ncode\n```\ntail"
        #expect(BlockParser.parse(text) == [b(.fencedCode, 0, 13), b(.paragraph, 13, 4)])
        assertTiles(text)
    }

    @Test("consecutive blockquote lines form one block, ended by a non-quote line")
    func blockquote() {
        let text = "> a\n> b\nc"
        #expect(BlockParser.parse(text) == [b(.blockquote, 0, 8), b(.paragraph, 8, 1)])
        assertTiles(text)
    }

    @Test("frontmatter only pairs at document start and unterminated openers stay thematic breaks")
    func frontmatterPairingIsDocumentScoped() {
        let text = "---\ntitle: x\n...\nbody"
        #expect(BlockParser.parse(text) == [
            b(.frontmatter, 0, 17),
            b(.paragraph, 17, 4),
        ])
        #expect(BlockParser.parse("---\ntitle: x") == [
            b(.thematicBreak, 0, 4),
            b(.paragraph, 4, 8),
        ])
        #expect(BlockParser.parse("body\n\n---\n") == [
            b(.paragraph, 0, 5),
            b(.blank, 5, 1),
            b(.thematicBreak, 6, 4),
        ])
        assertTiles(text)
    }

    @Test("consecutive link definitions group and retain every destination")
    func linkDefinitionsGroup() {
        let text = " [One]: <https://example.com/a b> \"title\"\n[Two]: /two\n\nbody"
        let blocks = BlockParser.parse(text)
        #expect(blocks.map(\.kind) == [.linkDefinition, .blank, .paragraph])
        #expect(blocks[0].range == NSRange(location: 0, length: 54))

        let definitions = DocumentAST.parse(text).compactMap { node -> (String, String)? in
            guard case .linkDefinition(_, let label, let destination, _) = node else { return nil }
            let ns = text as NSString
            return (ns.substring(with: label), ns.substring(with: destination))
        }
        #expect(definitions.map(\.0) == ["One", "Two"])
        #expect(definitions.map(\.1) == ["https://example.com/a b", "/two"])
        assertTiles(text)
    }

    @Test("link definitions find unescaped angle closers and retain source bytes")
    func escapedLinkDefinitionDestination() throws {
        let text = #"[id]: <https://example.com/a\>b> "ti\*tle""#
        let node = try #require(DocumentAST.parse(text).first)
        guard case .linkDefinition(let range, _, let destination, let title) = node else {
            Issue.record("Expected link definition")
            return
        }
        let ns = text as NSString
        #expect(ns.substring(with: range) == text)
        #expect(ns.substring(with: destination) == #"https://example.com/a\>b"#)
        #expect(MarkdownLinkSyntax.unescapedText(in: ns, range: destination)
            == "https://example.com/a>b")
        #expect(title.map { MarkdownLinkSyntax.unescapedText(in: ns, range: $0) }
            == "ti*tle")

        let malformed = #"[id]: <https://example.com/a\>"#
        #expect(BlockParser.parse(malformed).first?.kind == .paragraph)
    }

    @Test("footnote definitions include four-space continuation lines")
    func footnoteDefinitionContinuation() throws {
        let text = "[^note]: first\n    *second*\nplain"
        #expect(BlockParser.parse(text).map(\.kind) == [.footnoteDefinition, .paragraph])
        let node = try #require(DocumentAST.parse(text).first)
        guard case .footnoteDefinition(let range, let label, let markers, let inlines) = node else {
            Issue.record("Expected footnote definition")
            return
        }
        #expect(range == NSRange(location: 0, length: 28))
        #expect((text as NSString).substring(with: label) == "note")
        #expect(markers.count == 3)
        #expect(inlines.contains { if case .emphasis = $0 { return true }; return false })
        assertTiles(text)
    }

    @Test("frontmatter and tilde delimiters force a full incremental parse")
    func newPairedDelimitersRipple() {
        for text in ["---\n", "...\n", "~~~swift\n"] {
            let chars = Array(text.utf16)
            #expect(BlockParser.hasBlockDelimiter(chars, 0, chars.count))
        }
    }

    @Test("setext underline closes a paragraph before thematic-break classification")
    func setextHeadingPrecedesThematicBreak() {
        let text = "Title\n---\nbody"
        #expect(BlockParser.parse(text) == [
            b(.heading, 0, 10),
            b(.paragraph, 10, 4),
        ])
        if let first = DocumentAST.parse(text).first,
           case .heading(let level, let range, let markers, _) = first {
            #expect(level == 2)
            #expect(range == NSRange(location: 0, length: 10))
            #expect(markers == [NSRange(location: 6, length: 4)])
        } else {
            Issue.record("Expected setext heading node")
        }
        #expect(BlockParser.parse("Title\n = \t\n") == [b(.heading, 0, 11)])
        assertTiles(text)
    }

    @Test("setext underline only closes paragraphs")
    func setextDoesNotCloseOtherBlocks() {
        #expect(BlockParser.parse("# Heading\n---\n").map(\.kind) == [.heading, .thematicBreak])
        #expect(BlockParser.parse("- item\n---\n").map(\.kind) == [.list, .thematicBreak])
        #expect(BlockParser.parse("> quote\n---\n").map(\.kind) == [.blockquote, .thematicBreak])
        #expect(BlockParser.parse("\n---\n").map(\.kind) == [.blank, .thematicBreak])
    }

    @Test("tilde fences require matching characters and sufficient closing length")
    func tildeFencePairing() {
        let text = "~~~~swift\nx\n~~~~~\n"
        #expect(BlockParser.parse(text) == [b(.fencedCode, 0, 18)])
        let token = MarkdownTokenizer.parseTokensViaAST(in: text).first { $0.kind == .codeBlock }
        #expect(token.flatMap { MarkdownTokenizer.extractLanguage(from: $0, in: text) } == "swift")
        #expect(!BlockParser.parse("~~~~\nx\n~~~\n").contains { $0.kind == .fencedCode })
        #expect(!BlockParser.parse("~~~\nx\n```\n").contains { $0.kind == .fencedCode })
    }

    @Test("indented code keeps internal blanks but leaves trailing blanks outside")
    func indentedCodeBlock() {
        let text = "    one\n\n\t two\n\nbody"
        #expect(BlockParser.parse(text) == [
            b(.fencedCode, 0, 15),
            b(.blank, 15, 1),
            b(.paragraph, 16, 4),
        ])
        #expect(BlockParser.parse("    # literal heading\n").map(\.kind) == [.fencedCode])
        assertTiles(text)
    }

    @Test("indented code cannot interrupt a paragraph or split list content")
    func indentedCodePrecedence() throws {
        #expect(BlockParser.parse("paragraph\n    continuation\n").map(\.kind) == [.paragraph])
        #expect(BlockParser.parse("- item\n    continuation\n").map(\.kind) == [.list])
        let node = try #require(DocumentAST.parse("- item\n    continuation\n").first)
        guard case .list(_, let items) = node else {
            Issue.record("Expected list")
            return
        }
        #expect(items.count == 1)
    }

    @Test("spaced thematic breaks win over lists while ordinary bullets remain lists")
    func spacedThematicBreaks() {
        for source in ["- - -\n", "* * *\n", "_ _ _\n", "-  -  -\n"] {
            #expect(BlockParser.parse(source).map(\.kind) == [.thematicBreak], "source \(source.debugDescription)")
        }
        #expect(BlockParser.parse("- item\n").map(\.kind) == [.list])
    }
}

//
//  TableCellSourceTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.08.26.
//
//  What a GFM row can and cannot hold: the delimiter is escapable, and `<br>`
//  is the only line break a cell has — a row IS one source line.
//

import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Table cell source")
@MainActor
struct TableCellSourceTests {

    // MARK: - Escaped delimiters

    @Test func escapedPipeKeepsTheRowInOneCell() throws {
        let source = """
        | Statement | Verdict |
        |---|---|
        | `P(k)` does not depend on `z̄` | **TRUE**. `Var[x(1) \\| z(1:3)]`-style claims go by *index* |
        """
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let row = try #require(parsed.rows.first)
        #expect(row.count == 2)
        // Everything past the first `\|` used to be dropped on the floor.
        #expect(row[1].hasSuffix("by *index*"))
        // …and the escape resolves to the literal character GFM promises.
        #expect(row[1].contains("Var[x(1) | z(1:3)]"))
        #expect(!row[1].contains("\\|"))
    }

    @Test func escapedPipeInsideCodeMatchesRenderedAndAccessibleText() throws {
        let source = """
        | Statement | Verdict |
        |---|---|
        | `P(k)` | `Var[x(1) \\| z(1:3)]` |
        """
        let expected = "Statement\tVerdict\nP(k)\tVar[x(1) | z(1:3)]"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let cell = try #require(parsed.rows.first?.last)
        let formatted = MarkdownStyler.formattedCellString(
            cell,
            baseFont: .systemFont(ofSize: 15),
            header: false,
            theme: MarkdownEditorConfiguration.default.theme,
            codeBackgroundColor: .windowBackgroundColor
        )
        let projection = MarkdownTextProjection.make(markdown: source)
        let accessibility = MarkdownAccessibilityProjection.make(markdown: source)

        #expect(formatted.string == "Var[x(1) | z(1:3)]")
        #expect(projection.string == expected)
        #expect(accessibility.text.string == expected)
        #expect(accessibility.spans.isEmpty)

        let ns = source as NSString
        let marker = ns.range(of: #"\|"#)
        let pipe = NSRange(location: marker.location + 1, length: 1)
        let visiblePipe = try #require(projection.visibleRange(for: pipe))
        #expect((projection.string as NSString).substring(with: visiblePipe) == "|")
        #expect(projection.visibleRange(for: NSRange(location: marker.location, length: 1))?.length == 0)
        #expect(projection.sourceRange(for: visiblePipe) == pipe)
    }

    @Test func escapedPipeNormalizationKeepsBackslashParity() {
        let row = MarkdownTableRowSource.row(#"\| \\| \\\|"#)

        #expect(row.delimiters.count == 1)
        #expect(row.cells.map(\.normalizedText) == [#"| \\"#, #"\\|"#])
        #expect(row.cells.flatMap(\.escapedPipeMarkers).count == 2)
    }

    @Test func everyNormalizedRangeMapsToAValidUTF16SourceRange() throws {
        let sources = [
            #"\|"#,
            #"a\|b"#,
            #"\|a\|"#,
            #"🧑🏽‍💻\|z"#,
            #"[a\|b](u\|v)"#,
        ]
        for source in sources {
            let cell = try #require(
                MarkdownTableRowSource.row("| \(source) |").cells.first
            )
            let normalizedLength = (cell.normalizedText as NSString).length
            for location in 0...normalizedLength {
                for length in 0...(normalizedLength - location) {
                    let mapped = try #require(cell.sourceRange(
                        forNormalizedRange: NSRange(location: location, length: length)
                    ))
                    #expect(mapped.location >= cell.sourceRange.location)
                    #expect(mapped.length >= 0)
                    #expect(NSMaxRange(mapped) <= NSMaxRange(cell.sourceRange))
                }
            }
        }

        let escapedPipe = try #require(MarkdownTableRowSource.row(#"| \| |"#).cells.first)
        #expect(escapedPipe.sourceRange(forNormalizedRange: NSRange(location: 0, length: 0))
            == NSRange(location: escapedPipe.sourceRange.location + 1, length: 0))
    }

    @Test func escapedPipeLinkSemanticsUseRenderedCellSource() throws {
        let source = #"""
        | Link | Image |
        |---|---|
        | [a\|b](https://example.com/a\|b) | ![c\|d](image\|x.png) |
        """#
        let projection = MarkdownAccessibilityProjection.make(markdown: source)
        let link = try #require(projection.spans.first { span in
            if case .link = span.role { return true }
            return false
        })
        let image = try #require(projection.spans.first { span in
            if case .image = span.role { return true }
            return false
        })
        let visible = (projection.text.string as NSString).substring(with: link.visibleRange)
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let cell = try #require(parsed.rows.first?.first)

        #expect(projection.text.string == "Link\tImage\na|b\tc|d")
        #expect(link.role == .link(destination: "https://example.com/a|b"))
        #expect(image.role == .image(label: "c|d", destination: "image|x.png"))
        #expect(visible == "a|b")
        #expect(cell == #"[a|b](https://example.com/a|b)"#)
    }

    @Test func cellsBeyondRenderedWidthStayHiddenFromProjectionAndAccessibility() throws {
        let source = """
        | A | B |
        |---|---|
        | one | two | [🧑🏽‍💻hidden](https://example.com) | ![also hidden](image.png) |
        """
        let projection = MarkdownTextProjection.make(markdown: source)
        let accessibility = MarkdownAccessibilityProjection.make(markdown: source)
        let ns = source as NSString
        let hidden = ns.range(of: "[🧑🏽‍💻hidden](https://example.com)")
        let hiddenImage = ns.range(of: "![also hidden](image.png)")
        let visibleTwo = ns.range(of: "two")

        #expect(projection.string == "A\tB\none\ttwo")
        #expect(accessibility.text.string == projection.string)
        #expect(accessibility.spans.isEmpty)
        #expect(projection.visibleRange(for: hidden)?.length == 0)
        #expect(projection.visibleRange(for: hiddenImage)?.length == 0)
        #expect(!projection.string.contains("hidden"))
        #expect((projection.string as NSString).range(of: "https://example.com").location == NSNotFound)
        let projectedTwo = try #require(projection.visibleRange(for: visibleTwo))
        #expect(projection.sourceRange(for: projectedTwo) == visibleTwo)
        #expect(!MarkdownHTMLRenderer.html(from: source).contains("hidden"))
    }

    @Test func directAndReferenceTableMediaUseSemanticVisibleText() throws {
        let source = """
        | Link | Image |
        |---|---|
        | [direct](https://direct.example) | ![Direct alt](direct.png) |
        | [reference][link] | ![Reference alt][image] |

        [link]: https://reference.example
        [image]: reference.png
        """
        let parsed = try #require(MarkdownStyler.parseTableSource(
            source.components(separatedBy: "\n\n")[0]
        ))
        let definitions: Set<String> = ["link", "image"]
        let renderedRows = parsed.rows.map { row in
            row.map {
                MarkdownStyler.formattedCellString(
                    $0,
                    baseFont: .systemFont(ofSize: 15),
                    header: false,
                    theme: MarkdownEditorConfiguration.default.theme,
                    codeBackgroundColor: .windowBackgroundColor,
                    referenceDefinitions: definitions
                ).string
            }.joined(separator: "\t")
        }
        let projection = MarkdownTextProjection.make(markdown: source)
        let accessibility = MarkdownAccessibilityProjection.make(markdown: source)

        #expect(renderedRows == ["direct\tDirect alt", "reference\tReference alt"])
        #expect(projection.string == "Link\tImage\ndirect\tDirect alt\nreference\tReference alt\n\n")
        #expect(accessibility.text.string == projection.string)
        #expect(accessibility.spans.contains {
            $0.role == .link(destination: "https://reference.example")
        })
        #expect(accessibility.spans.contains {
            $0.role == .image(label: "Reference alt", destination: "reference.png")
        })
        #expect(MarkdownHTMLRenderer.html(from: source).contains(
            #"<td><a href="https://direct.example">direct</a></td>"#
        ))
        #expect(MarkdownHTMLRenderer.html(from: source).contains(
            #"<td><img src="direct.png" alt="Direct alt"></td>"#
        ))
        #expect(MarkdownHTMLRenderer.html(from: source).contains(
            #"<td><a href="https://reference.example">reference</a></td>"#
        ))
        #expect(MarkdownHTMLRenderer.html(from: source).contains(
            #"<td><img src="reference.png" alt="Reference alt"></td>"#
        ))
    }

    // MARK: - In-cell line breaks

    @Test func brRendersAsALineBreakInsteadOfLiteralText() {
        let cell = MarkdownStyler.formattedCellString(
            "first<br>second",
            baseFont: .systemFont(ofSize: 15),
            header: false,
            theme: MarkdownEditorConfiguration.default.theme,
            codeBackgroundColor: .windowBackgroundColor
        )
        #expect(cell.string == "first\nsecond")
    }

    @Test func aCellBrokenByBrMakesItsRowTaller() throws {
        func height(_ source: String) throws -> CGFloat {
            let parsed = try #require(MarkdownStyler.parseTableSource(source))
            let font = NSFont.systemFont(ofSize: 15)
            var ctx = MarkdownStyler.StylingContext(
                nsText: source as NSString,
                tokens: [], codeTokens: [], activeTokenIndices: [],
                baseFont: font, layoutBridge: nil, baseDefaultLineHeight: 18,
                codeBackgroundColor: .windowBackgroundColor, hiddenMarkerFont: font,
                configuration: .default
            )
            ctx.scopeBounds = nil
            let aqua = try #require(NSAppearance(named: .aqua))
            return MarkdownStyler.tableImage(
                for: source, parsed: parsed, ctx: ctx, appearance: aqua, availableWidth: 650
            ).image.size.height
        }
        let flat = try height("| A | B |\n|---|---|\n| one | two |")
        let broken = try height("| A | B |\n|---|---|\n| one | two<br>three |")
        #expect(broken > flat + 5)
    }

    // MARK: - Return inside a row

    private func textView(_ text: String) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.string = text
        return tv
    }

    @Test func returnInsideARowInsertsABreakInsteadOfSplittingIt() throws {
        let source = "| A | B |\n|---|---|\n| one | two |"
        let tv = textView(source)
        let tables = MarkdownTokenizer.parseTokensViaAST(in: source).filter { $0.kind == .table }
        let caret = (source as NSString).range(of: "two").upperBound

        let handled = MarkdownInputHandler.handleTableCellNewline(
            textView: tv,
            affectedCharRange: NSRange(location: caret, length: 0),
            replacementString: "\n",
            tableTokens: tables
        )
        #expect(handled)
        #expect(tv.string == "| A | B |\n|---|---|\n| one | two<br> |")
        #expect(tv.selectedRange().location == caret + 4)
    }

    /// The table's outer edges stay a plain newline — otherwise a table that
    /// reaches the end of the document has no way out.
    @Test func returnAtTheTableEdgesStaysANormalNewline() {
        let source = "| A | B |\n|---|---|\n| one | two |"
        let tables = MarkdownTokenizer.parseTokensViaAST(in: source).filter { $0.kind == .table }
        for caret in [0, (source as NSString).length] {
            let tv = textView(source)
            let handled = MarkdownInputHandler.handleTableCellNewline(
                textView: tv,
                affectedCharRange: NSRange(location: caret, length: 0),
                replacementString: "\n",
                tableTokens: tables
            )
            #expect(!handled)
            #expect(tv.string == source)
        }
    }

    @Test func returnOutsideAnyTableIsUntouched() {
        let source = "just prose\n\n| A | B |\n|---|---|\n| one | two |"
        let tv = textView(source)
        let tables = MarkdownTokenizer.parseTokensViaAST(in: source).filter { $0.kind == .table }
        let handled = MarkdownInputHandler.handleTableCellNewline(
            textView: tv,
            affectedCharRange: NSRange(location: 4, length: 0),
            replacementString: "\n",
            tableTokens: tables
        )
        #expect(!handled)
        #expect(tv.string == source)
    }
}

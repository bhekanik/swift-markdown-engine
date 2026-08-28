//
//  MarkdownTextProjectionTests.swift
//  MarkdownEngineTests
//

import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Visible text projection")
struct MarkdownTextProjectionTests {
    private func project(
        _ source: String,
        extensions: [any MarkdownExtension] = [HighlightExtension(), StrikethroughExtension()]
    ) -> MarkdownTextProjection {
        var configuration = MarkdownEditorConfiguration.default
        configuration.extensions = extensions
        return .make(markdown: source, configuration: configuration)
    }

    @Test("raw source is one identity span")
    func rawSourceIsIdentity() {
        let source = "👩🏽‍💻 **cafe\u{301}**\n"
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = true
        let projection = MarkdownTextProjection.make(
            markdown: source,
            configuration: configuration
        )
        let fullRange = NSRange(location: 0, length: (source as NSString).length)

        #expect(projection.string == source)
        #expect(projection.spans == [MarkdownTextProjectionSpan(
            sourceRange: fullRange,
            visibleRange: fullRange
        )])
    }

    @Test("inline syntax and hidden destinations are omitted")
    func projectsInlineContent() {
        let source = #"A **bold** [link](https://example.com) ![Alt](image.png) \*literal ` code ` <a@b.com> [^n]."#
        let projection = project(source)

        #expect(projection.string == "A bold link Alt *literal code a@b.com n.")
        #expect(!projection.string.contains("https://"))
        #expect(!projection.string.contains("image.png"))
    }

    @Test("block syntax is omitted but content and line boundaries remain")
    func projectsBlocks() {
        let source = """
        ---
        title: Hidden
        ---
        # Heading
        > quote
        - [x] task
        ```swift
        let value = 1
        ```
        ---
        """
        let projection = project(source)

        #expect(projection.string == "Heading\nquote\ntask\nlet value = 1\n")
        #expect(!projection.string.contains("Hidden"))
        #expect(!projection.string.contains("swift"))
    }

    @Test("tables use tabs, retain escaped pipes and turn br into a newline")
    func projectsRenderedTableCells() {
        let source = """
        | A | B |
        |---|---|
        | one | two<br>three |
        | escaped \\| pipe | **bold** |

        """
        let projection = project(source)

        #expect(projection.string == "A\tB\none\ttwo\nthree\nescaped | pipe\tbold\n")
    }

    @Test("resolved references hide their labels and definitions; orphans stay literal")
    func projectsReferenceLinks() {
        let source = """
        A [known][id] and [orphan][missing].

        [id]: https://example.com
        """
        let projection = project(source)

        #expect(projection.string == "A known and [orphan][missing].\n\n")
    }

    @Test("every projected span round-trips across all golden constructs")
    func goldenSpansRoundTrip() {
        for entry in GoldenCorpusTests.corpus {
            let projection = project(entry.markdown)
            for span in projection.spans {
                #expect(
                    projection.sourceRange(for: span.visibleRange) == span.sourceRange,
                    "source mapping failed for \(entry.name): \(span)"
                )
                #expect(
                    projection.visibleRange(for: span.sourceRange) == span.visibleRange,
                    "visible mapping failed for \(entry.name): \(span)"
                )
            }
        }
    }

    @Test("unicode content survives without split scalar or grapheme ranges")
    func unicodeBoundariesStayWhole() {
        let source = "👩🏽‍💻 **cafe\u{301}** and `😀`"
        let projection = project(source)

        #expect(projection.string == "👩🏽‍💻 cafe\u{301} and 😀")
        let visible = projection.string
        for span in projection.spans {
            let start = String.Index(utf16Offset: span.visibleRange.location, in: visible)
            let end = String.Index(utf16Offset: NSMaxRange(span.visibleRange), in: visible)
            #expect(visible.indices.contains(start) || start == visible.endIndex)
            #expect(visible.indices.contains(end) || end == visible.endIndex)
        }
    }

    @Test("invalid ranges are refused and hidden blocks map to a boundary")
    func rangeValidationAndHiddenMapping() {
        let source = "---\ntitle: Hidden\n---\nVisible"
        let projection = project(source)
        let hidden = (source as NSString).range(of: "Hidden")

        #expect(projection.visibleRange(for: hidden) == NSRange(location: 0, length: 0))
        #expect(projection.sourceRange(for: NSRange(location: NSNotFound, length: 0)) == nil)
        #expect(projection.visibleRange(for: NSRange(location: 0, length: Int.max)) == nil)
    }
}

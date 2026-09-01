import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Markdown semantic projection")
struct MarkdownSemanticProjectionTests {
    @Test("emphasis follows delimiter grammar and preserves nesting")
    func emphasisSemantics() {
        let source = #"**bold _nested_** snake_case_value \*literal\* ** one **"#
        let projection = MarkdownSemanticProjection.make(markdown: source)
        #expect(projection.spans.filter { $0.kind == .emphasis(.bold) }.map(\.range) == [
            (source as NSString).range(of: "**bold _nested_**"),
        ])
        #expect(projection.spans.filter { $0.kind == .emphasis(.italic) }.map(\.range) == [
            (source as NSString).range(of: "_nested_"),
        ])
    }

    @Test("separate runs expose separate semantic ranges")
    func separateRuns() {
        for source in ["**one** gap **two**", "_one_ gap _two_"] {
            let projection = MarkdownSemanticProjection.make(markdown: source)
            #expect(projection.spans.filter {
                if case .emphasis = $0.kind { true } else { false }
            }.count == 2)
        }
    }

    @Test("inline, fenced, and indented code expose source ranges")
    func codeRanges() {
        let inline = "before `literal` after"
        let inlineSpan = MarkdownSemanticProjection.make(markdown: inline).spans.first
        #expect(inlineSpan?.kind == .inlineCode)
        #expect(inlineSpan?.range == (inline as NSString).range(of: "`literal`"))
        #expect(inlineSpan?.contentRange == (inline as NSString).range(of: "literal"))

        for source in ["```swift\nlet value\n```", "~~~\nlet value\n~~~", "    let value"] {
            let span = MarkdownSemanticProjection.make(markdown: source).spans.first
            #expect(span?.kind == .codeBlock)
            #expect(span?.range == NSRange(location: 0, length: (source as NSString).length))
            #expect(span.map { NSLocationInRange((source as NSString).range(of: "let value").location, $0.contentRange) } == true)
        }
    }

    @Test("container fences are block code and suppress inline semantics")
    func containerCodeRanges() {
        for source in [
            "> ```swift\n> **let value**\n> ```",
            "- ~~~swift\n  **let value**\n  ~~~",
            "> - ```swift\n>   **let value**\n>   ```",
            "1. > ~~~swift\n   > **let value**\n   > ~~~",
            "> ```swift\n> **let value**",
        ] {
            let spans = MarkdownSemanticProjection.make(markdown: source).spans
            #expect(spans.count == 1)
            #expect(spans.first?.kind == .codeBlock)
            #expect(spans.first.map {
                NSLocationInRange(
                    (source as NSString).range(of: "let value").location,
                    $0.contentRange
                )
            } == true)
        }
    }

    @Test("container fences stop when their container ends")
    func containerFenceTermination() {
        for source in [
            "> ```\n> code\noutside prose\n```",
            "- ```\n  code\noutside prose\n```",
            "> - ```\n>   code\n> outside prose\n> ```",
            "1. > ~~~\n   > code\n\noutside prose\n~~~",
        ] {
            let code = MarkdownSemanticProjection.make(markdown: source).spans.first {
                $0.kind == .codeBlock
            }
            let outside = (source as NSString).range(of: "outside prose")
            #expect(code != nil)
            #expect(code.map { NSIntersectionRange($0.range, outside).length } == 0)
        }
    }

    @Test("blank lines continue fenced code in list containers")
    func listFenceBlankLines() {
        for source in [
            "- ```\n  before\n\n  after\n  ```",
            "- parent\n  - ```\n    before\n \n\n    after\n    ```",
        ] {
            let projection = MarkdownSemanticProjection.make(markdown: source)
            let code = projection.spans.first { $0.kind == .codeBlock }
            #expect(code.map {
                NSLocationInRange(
                    (source as NSString).range(of: "after").location,
                    $0.contentRange
                )
            } == true)
            #expect(code?.markerRanges.count == 2)
        }
    }

    @Test("registered inline extensions remain generic")
    func extensionRanges() {
        let source = "~~strike~~"
        let configuration = MarkdownEditorConfiguration(extensions: [StrikethroughExtension()])
        let span = MarkdownSemanticProjection.make(markdown: source, configuration: configuration).spans.first
        #expect(span?.kind == .inlineExtension(identifier: StrikethroughExtension.identifier))
        #expect(span?.contentRange == (source as NSString).range(of: "strike"))
    }

    @Test("table cell semantics map back through escaped pipes")
    func tableCellRanges() {
        let source = #"""
        | **bold** | `a\|b` | ~~strike~~ |
        | --- | --- | --- |
        """#
        let configuration = MarkdownEditorConfiguration(extensions: [StrikethroughExtension()])
        let spans = MarkdownSemanticProjection.make(
            markdown: source,
            configuration: configuration
        ).spans
        #expect(spans.map(\.range) == [
            (source as NSString).range(of: "**bold**"),
            (source as NSString).range(of: #"`a\|b`"#),
            (source as NSString).range(of: "~~strike~~"),
        ])
        #expect(spans.map(\.contentRange) == [
            (source as NSString).range(of: "bold"),
            (source as NSString).range(of: #"a\|b"#),
            (source as NSString).range(of: "strike"),
        ])
    }

    @Test("scoped projection returns only intersecting semantics")
    func scopedProjection() {
        let source = "**one** plain **two**\n\n```\ncode\n```"
        let two = (source as NSString).range(of: "two")
        let scoped = MarkdownSemanticProjection.make(
            markdown: source,
            intersecting: two
        )
        #expect(scoped.spans.map(\.range) == [(source as NSString).range(of: "**two**")])

        let code = (source as NSString).range(of: "code")
        #expect(MarkdownSemanticProjection.make(
            markdown: source,
            intersecting: code
        ).spans.map(\.kind) == [.codeBlock])

        let unclosed = "```\ncode"
        let eof = NSRange(location: (unclosed as NSString).length, length: 0)
        let eofProjection = MarkdownSemanticProjection.make(
            markdown: unclosed,
            intersecting: eof
        )
        #expect(eofProjection.spans.map(\.kind) == [.codeBlock])
        #expect(eofProjection.spans.first?.markerRanges.count == 1)
    }
}

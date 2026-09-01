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

        for source in [
            ">     let value", "-     let value", "1.     let value",
            ">   \tlet value", "-   \tlet value", "1.   \tlet value",
            "> \t    let value", "- \t    let value", "1. \t    let value",
        ] {
            let span = MarkdownSemanticProjection.make(
                markdown: source,
                intersecting: (source as NSString).range(of: "let value")
            ).spans.first
            #expect(span?.kind == .codeBlock)
            #expect(span.map {
                NSLocationInRange(
                    (source as NSString).range(of: "let value").location,
                    $0.contentRange
                )
            } == true)
        }
    }

    @Test("scoped projection checks every selected container-indented code line")
    func scopedMultilineContainerIndentedCode() {
        for separator in ["\n", "\r\n"] {
            for codeLine in [">     code", "-     code", "1.     code"] {
                let source = "prose\(separator)\(codeLine)\(separator)tail"
                let selection = (source as NSString).range(of: "prose\(separator)\(codeLine)")
                let projection = MarkdownSemanticProjection.make(
                    markdown: source,
                    intersecting: selection
                )
                let code = projection.spans.first { $0.kind == .codeBlock }
                #expect(code.map {
                    NSLocationInRange((source as NSString).range(of: "code").location, $0.contentRange)
                } == true)
            }
        }
    }

    @Test("local projection stops delimiter checks at LF and CRLF paragraph boundaries")
    func scopedProjectionParagraphBoundary() {
        for separator in ["\n\n", "\r\n\r\n"] {
            let source = "**old**\(separator)plain\n**target**"
            let target = (source as NSString).range(of: "target")
            let projection = MarkdownSemanticProjection.make(
                markdown: source,
                intersecting: target
            )
            #expect(projection.spans.map(\.range) == [(source as NSString).range(of: "**target**")])
        }
    }

    @Test("scoped projection preserves registered block extensions")
    func scopedBlockExtensions() {
        let configuration = MarkdownEditorConfiguration(extensions: [ContainerExtension()])
        for source in [":::\ninside\n:::", ":::\ninside", ":::\r\ninside\r\n:::"] {
            let selection = (source as NSString).range(of: "inside")
            let full = MarkdownSemanticProjection.make(
                markdown: source,
                configuration: configuration
            )
            let scoped = MarkdownSemanticProjection.make(
                markdown: source,
                intersecting: selection,
                configuration: configuration
            )
            #expect(scoped.spans == full.spans.filter {
                NSIntersectionRange($0.range, selection).length > 0
            })
            #expect(scoped.spans.map(\.kind) == [
                .blockExtension(identifier: ContainerExtension.identifier),
            ])
        }
    }

    @Test("scoped projection preserves multiline block context")
    func scopedMultilineBlockContext() {
        for separator in ["\n", "\r\n"] {
            for source in [
                "---\(separator)title: **inside**\(separator)---",
                "- first\(separator)    **inside**",
                "[^1]: first\(separator)    **inside**",
            ] {
                let selection = (source as NSString).range(of: "inside")
                let full = MarkdownSemanticProjection.make(markdown: source)
                let scoped = MarkdownSemanticProjection.make(
                    markdown: source,
                    intersecting: selection
                )
                #expect(scoped.spans == full.spans.filter {
                    NSIntersectionRange($0.range, selection).length > 0
                })
            }
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

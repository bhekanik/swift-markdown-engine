//
//  MarkdownAccessibilityProjectionTests.swift
//  MarkdownEngineTests
//

import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Markdown accessibility projection")
struct MarkdownAccessibilityProjectionTests {
    private func project(_ source: String) -> MarkdownAccessibilityProjection {
        .make(markdown: source)
    }

    @Test("headings, lists, links, images and footnotes keep visible ranges")
    func exposesStructure() {
        let source = """
        ## Heading [link](https://example.com)
        - [x] task
        ![Alt](image.png)
        Note[^n].

        [^n]: Footnote body
        """
        let projection = project(source)

        #expect(projection.text.string == "Heading link\ntask\nAlt\nNoten.\n\nnFootnote body")
        #expect(projection.spans.contains { span in
            span.role == .heading(level: 2)
                && substring(span.visibleRange, in: projection.text.string) == "Heading link\n"
        })
        #expect(projection.spans.contains { span in
            span.role == .listItem(level: 0, index: 0, prefix: "•", isChecked: true)
                && substring(span.visibleRange, in: projection.text.string) == "task"
        })
        #expect(projection.spans.contains { span in
            span.role == .link(destination: "https://example.com")
                && substring(span.visibleRange, in: projection.text.string) == "link"
        })
        #expect(projection.spans.contains { span in
            span.role == .image(label: "Alt", destination: "image.png")
                && substring(span.visibleRange, in: projection.text.string) == "Alt"
        })
        #expect(projection.spans.contains { span in
            span.role == .footnoteReference(label: "n")
                && substring(span.visibleRange, in: projection.text.string) == "n"
        })
        #expect(projection.spans.contains { span in
            span.role == .footnoteDefinition(label: "n")
                && substring(span.visibleRange, in: projection.text.string) == "nFootnote body"
        })
    }

    @Test("resolved reference and table links expose their destinations")
    func resolvesLinksAcrossBlocks() {
        let source = """
        | Name |
        |---|
        | [inline](https://inline.example) |

        [reference][id]

        [id]: https://reference.example
        """
        let projection = project(source)
        let links = projection.spans.compactMap { span -> String? in
            guard case .link(let destination) = span.role else { return nil }
            return destination
        }

        #expect(links.contains("https://inline.example"))
        #expect(links.contains("https://reference.example"))
    }

    @Test("escaped inline, image, and reference destinations expose decoded semantics")
    func escapedDestinations() {
        let source = #"""
[inline](<https://example.com/a\>b>)
![image](https://example.com/a\)b)
[reference][id]

[id]: <https://example.com/a\>b>
"""#
        let projection = project(source)

        #expect(projection.text.string == "inline\nimage\nreference\n\n")
        #expect(projection.spans.contains {
            $0.role == .link(destination: "https://example.com/a>b")
                && substring($0.visibleRange, in: projection.text.string) == "inline"
        })
        #expect(projection.spans.contains {
            $0.role == .image(label: "image", destination: "https://example.com/a)b")
        })
        #expect(projection.spans.contains {
            $0.role == .link(destination: "https://example.com/a>b")
                && substring($0.visibleRange, in: projection.text.string) == "reference"
        })
    }

    @Test("escaped image descriptions expose decoded labels")
    func escapedImageDescriptions() {
        let source = #"![escaped\*alt](image.png) ![escaped\]alt](image.png) ![slash\\](image.png)"#
        let projection = project(source)

        #expect(projection.text.string == #"escaped*alt escaped]alt slash\"#)
        #expect(projection.spans.map(\.role) == [
            .image(label: "escaped*alt", destination: "image.png"),
            .image(label: "escaped]alt", destination: "image.png"),
            .image(label: #"slash\"#, destination: "image.png"),
        ])
    }

    @Test("invalid bare destination escapes expose no semantic roles")
    func invalidBareDestinationEscapes() {
        let cases = [
            #"[x](https://example.com/a\ b)"#,
            #"[x](https://example.com/a\\ b)"#,
            "[x](https://example.com/a\\\nb)",
            #"![x](https://example.com/a\ b)"#,
            "[id]: /a\\ b\n\n[x][id]",
        ]

        for source in cases {
            #expect(project(source).spans.isEmpty)
        }
    }

    @Test("raw mode exposes source text without rendered structure")
    func rawModeIsUnstructuredSource() {
        let source = "# [Heading](https://example.com)\n"
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = true

        let projection = MarkdownAccessibilityProjection.make(
            markdown: source,
            configuration: configuration
        )

        #expect(projection.text.string == source)
        #expect(projection.spans.isEmpty)
    }

    private func substring(_ range: NSRange, in string: String) -> String {
        (string as NSString).substring(with: range)
    }
}

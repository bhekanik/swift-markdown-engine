//
//  CommonMarkReferenceConformanceTests.swift
//  MarkdownEngineTests
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("CommonMark reference association")
struct CommonMarkReferenceConformanceTests {
    private struct Fixture {
        let example: Int
        let markdown: String
        let html: String
        let visible: String
        let links: [String]
        let images: [(label: String, destination: String)]
    }

    private let fixtures: [Fixture] = [
        .init(
            example: 523,
            markdown: "*foo [bar* baz]\n",
            html: "<p><em>foo [bar</em> baz]</p>",
            visible: "foo [bar baz]\n",
            links: [], images: []
        ),
        .init(
            example: 528,
            markdown: "[link [foo [bar]]][ref]\n\n[ref]: /uri\n",
            html: "<p><a href=\"/uri\">link [foo [bar]]</a></p>",
            visible: "link [foo [bar]]\n\n",
            links: ["/uri"], images: []
        ),
        .init(
            example: 534,
            markdown: "*[foo*][ref]\n\n[ref]: /uri\n",
            html: "<p>*<a href=\"/uri\">foo*</a></p>",
            visible: "*foo*\n\n",
            links: ["/uri"], images: []
        ),
        .init(
            example: 535,
            markdown: "[foo *bar][ref]*\n\n[ref]: /uri\n",
            html: "<p><a href=\"/uri\">foo *bar</a>*</p>",
            visible: "foo *bar*\n\n",
            links: ["/uri"], images: []
        ),
        .init(
            example: 546,
            markdown: "[foo][ref[]\n\n[ref[]: /uri\n",
            html: "<p>[foo][ref[]</p>\n<p>[ref[]: /uri</p>",
            visible: "[foo][ref[]\n\n[ref[]: /uri\n",
            links: [], images: []
        ),
        .init(
            example: 549,
            markdown: "[foo][ref\\[]\n\n[ref\\[]: /uri\n",
            html: "<p><a href=\"/uri\">foo</a></p>",
            visible: "foo\n\n",
            links: ["/uri"], images: []
        ),
        .init(
            example: 569,
            markdown: "[foo][bar][baz]\n\n[baz]: /url\n",
            html: "<p>[foo]<a href=\"/url\">bar</a></p>",
            visible: "[foo]bar\n\n",
            links: ["/url"], images: []
        ),
        .init(
            example: 570,
            markdown: "[foo][bar][baz]\n\n[baz]: /url1\n[bar]: /url2\n",
            html: "<p><a href=\"/url2\">foo</a><a href=\"/url1\">baz</a></p>",
            visible: "foobaz\n\n",
            links: ["/url2", "/url1"], images: []
        ),
        .init(
            example: 571,
            markdown: "[foo][bar][baz]\n\n[baz]: /url1\n[foo]: /url2\n",
            html: "<p>[foo]<a href=\"/url1\">bar</a></p>",
            visible: "[foo]bar\n\n",
            links: ["/url1"], images: []
        ),
        .init(
            example: 582,
            markdown: "![foo][bar]\n\n[bar]: /url\n",
            html: "<p><img src=\"/url\" alt=\"foo\"></p>",
            visible: "foo\n\n",
            links: [], images: [("foo", "/url")]
        ),
        .init(
            example: 583,
            markdown: "![foo][bar]\n\n[BAR]: /url\n",
            html: "<p><img src=\"/url\" alt=\"foo\"></p>",
            visible: "foo\n\n",
            links: [], images: [("foo", "/url")]
        ),
        .init(
            example: 584,
            markdown: "![foo][]\n\n[foo]: /url \"title\"\n",
            html: "<p><img src=\"/url\" alt=\"foo\" title=\"title\"></p>",
            visible: "foo\n\n",
            links: [], images: [("foo", "/url")]
        ),
        .init(
            example: 585,
            markdown: "![*foo* bar][]\n\n[*foo* bar]: /url \"title\"\n",
            html: "<p><img src=\"/url\" alt=\"foo bar\" title=\"title\"></p>",
            visible: "foo bar\n\n",
            links: [], images: [("foo bar", "/url")]
        ),
        .init(
            example: 586,
            markdown: "![Foo][]\n\n[foo]: /url \"title\"\n",
            html: "<p><img src=\"/url\" alt=\"Foo\" title=\"title\"></p>",
            visible: "Foo\n\n",
            links: [], images: [("Foo", "/url")]
        ),
        .init(
            example: 587,
            markdown: "![foo] \n[]\n\n[foo]: /url \"title\"\n",
            html: "<p><img src=\"/url\" alt=\"foo\" title=\"title\"> \n[]</p>",
            visible: "foo \n[]\n\n",
            links: [], images: [("foo", "/url")]
        ),
        .init(
            example: 588,
            markdown: "![foo]\n\n[foo]: /url \"title\"\n",
            html: "<p><img src=\"/url\" alt=\"foo\" title=\"title\"></p>",
            visible: "foo\n\n",
            links: [], images: [("foo", "/url")]
        ),
        .init(
            example: 589,
            markdown: "![*foo* bar]\n\n[*foo* bar]: /url \"title\"\n",
            html: "<p><img src=\"/url\" alt=\"foo bar\" title=\"title\"></p>",
            visible: "foo bar\n\n",
            links: [], images: [("foo bar", "/url")]
        ),
    ]

    @Test("official examples 523, 528, 534/535, 546/549, 569–571 and 582–589")
    func officialReferenceExamples() {
        for fixture in fixtures {
            let ast = DocumentAST.parse(fixture.markdown)
            let semantics = semanticInlines(in: ast)
            #expect(semantics.links == fixture.links.count, "CommonMark \(fixture.example)")
            #expect(semantics.images == fixture.images.count, "CommonMark \(fixture.example)")

            let rendered = MarkdownHTMLRenderer.html(from: fixture.markdown)
                .replacingOccurrences(of: "\n</p>", with: "</p>")
            #expect(rendered == fixture.html, "CommonMark \(fixture.example)")

            let projection = MarkdownTextProjection.make(markdown: fixture.markdown)
            #expect(projection.string == fixture.visible, "CommonMark \(fixture.example)")

            let accessibility = MarkdownAccessibilityProjection.make(markdown: fixture.markdown)
            #expect(accessibility.text.string == fixture.visible, "CommonMark \(fixture.example)")
            let links = accessibility.spans.compactMap { span -> String? in
                guard case .link(let destination) = span.role else { return nil }
                return destination
            }
            let images = accessibility.spans.compactMap { span -> (String, String)? in
                guard case .image(let label, let destination) = span.role else { return nil }
                return (label, destination)
            }
            #expect(links == fixture.links, "CommonMark \(fixture.example)")
            #expect(images.elementsEqual(fixture.images) { $0 == ($1.label, $1.destination) }, "CommonMark \(fixture.example)")

            let tokens = MarkdownTokenizer.parseTokensViaAST(in: fixture.markdown)
            #expect(tokens.filter { $0.kind == .imageLink }.count == fixture.images.count, "CommonMark \(fixture.example)")
            let styled = MarkdownRendering.attributedString(
                for: fixture.markdown,
                fontName: NSFont.systemFont(ofSize: 16).fontName,
                fontSize: 16
            )
            #expect(styled.string == fixture.markdown, "CommonMark \(fixture.example)")
            var styledLinkCount = 0
            styled.enumerateAttribute(.link, in: NSRange(location: 0, length: styled.length)) { value, _, _ in
                if value != nil { styledLinkCount += 1 }
            }
            #expect(styledLinkCount == fixture.links.count, "CommonMark \(fixture.example)")
        }
    }

    @Test("CommonMark 536–538 keep opaque inline brackets out of reference association")
    func opaqueInlineBrackets() {
        let cases: [(source: String, html: String, visible: String, destination: String?, styledDestination: String?)] = [
            (
                "[foo <bar attr=\"][ref]\">\n\n[ref]: /uri\n",
                "<p>[foo &lt;bar attr=&quot;][ref]&quot;&gt;</p>",
                "[foo <bar attr=\"][ref]\">\n\n",
                nil,
                nil
            ),
            (
                "[foo`][ref]`\n\n[ref]: /uri\n",
                "<p>[foo<code>][ref]</code></p>",
                "[foo][ref]\n\n",
                nil,
                nil
            ),
            (
                "[foo<https://example.com/?search=][ref]>\n\n[ref]: /uri\n",
                "<p>[foo<a href=\"https://example.com/?search=][ref]\">https://example.com/?search=][ref]</a></p>",
                "[foohttps://example.com/?search=][ref]\n\n",
                "https://example.com/?search=][ref]",
                "https://example.com/?search=%5D%5Bref%5D"
            ),
        ]

        for entry in cases {
            let rendered = MarkdownHTMLRenderer.html(from: entry.source)
                .replacingOccurrences(of: "\n</p>", with: "</p>")
            #expect(rendered == entry.html)

            let ast = DocumentAST.parse(entry.source)
            let counts = linkCounts(in: ast)
            #expect(counts.references == 0)
            #expect(counts.autolinks == (entry.destination == nil ? 0 : 1))

            #expect(MarkdownTextProjection.make(markdown: entry.source).string == entry.visible)
            let accessibility = MarkdownAccessibilityProjection.make(markdown: entry.source)
            #expect(accessibility.text.string == entry.visible)
            let destinations = accessibility.spans.compactMap { span -> String? in
                guard case .link(let destination) = span.role else { return nil }
                return destination
            }
            #expect(destinations == entry.destination.map { [$0] } ?? [])

            let styled = MarkdownRendering.attributedString(
                for: entry.source,
                fontName: NSFont.systemFont(ofSize: 16).fontName,
                fontSize: 16
            )
            var styledDestinations: [String] = []
            styled.enumerateAttribute(.link, in: NSRange(location: 0, length: styled.length)) { value, _, _ in
                if let url = value as? URL { styledDestinations.append(url.absoluteString) }
            }
            #expect(styledDestinations == entry.styledDestination.map { [$0] } ?? [])
        }

        let escapedAngle = #"[foo \<bar][ref]"# + "\n\n[ref]: /uri\n"
        #expect(MarkdownHTMLRenderer.html(from: escapedAngle).contains("href=\"/uri\""))
    }

    @Test("recognized angle spans control bracket association inside link and image labels")
    func quotedRawHTMLInsideLabels() {
        let referenceLabels = [
            #"outer <x attr="> [">"#,
            #"outer <x attr='> ['>"#,
        ]
        for label in referenceLabels {
            let source = "[\(label)][ref]\n\n[ref]: /uri\n"
            let ast = DocumentAST.parse(source)
            #expect(linkCounts(in: ast).references == 1)
            #expect(MarkdownHTMLRenderer.html(from: source)
                .contains("<a href=\"/uri\">\(escapedHTML(label))</a>"))
            #expect(MarkdownTextProjection.make(markdown: source).string == "\(label)\n\n")

            let accessibility = MarkdownAccessibilityProjection.make(markdown: source)
            #expect(accessibility.text.string == "\(label)\n\n")
            #expect(accessibility.spans.contains(where: { span in
                span.role == .link(destination: "/uri")
                    && span.visibleRange == NSRange(location: 0, length: (label as NSString).length)
            }))

            let styled = MarkdownRendering.attributedString(
                for: source,
                fontName: NSFont.systemFont(ofSize: 16).fontName,
                fontSize: 16
            )
            #expect(styled.attribute(.link, at: 1, effectiveRange: nil) != nil)
            #expect(styled.attribute(.link, at: (label as NSString).length, effectiveRange: nil) != nil)
        }

        let inlineLabel = #"outer <x attr="> [">"#
        let inline = "[\(inlineLabel)](https://example.com)"
        #expect(semanticInlines(in: DocumentAST.parse(inline)).links == 1)
        #expect(MarkdownHTMLRenderer.html(from: inline)
            == "<p><a href=\"https://example.com\">\(escapedHTML(inlineLabel))</a></p>")
        #expect(MarkdownTextProjection.make(markdown: inline).string == inlineLabel)
        #expect(MarkdownAccessibilityProjection.make(markdown: inline).spans.contains(where: {
            $0.role == .link(destination: "https://example.com")
        }))

        let imageLabel = #"outer <x attr='> ['>"#
        let image = "![\(imageLabel)](/image.png)"
        #expect(semanticInlines(in: DocumentAST.parse(image)).images == 1)
        #expect(MarkdownHTMLRenderer.html(from: image)
            == "<p><img src=\"/image.png\" alt=\"\(escapedHTML(imageLabel))\"></p>")
        #expect(MarkdownTextProjection.make(markdown: image).string == imageLabel)
        #expect(MarkdownAccessibilityProjection.make(markdown: image).spans.contains(where: {
            $0.role == .image(label: imageLabel, destination: "/image.png")
        }))

        for malformed in [#"outer <x attr=""#, #"outer <x attr=" ["#] {
            let source = "[\(malformed)][ref]\n\n[ref]: /uri\n"
            #expect(linkCounts(in: DocumentAST.parse(source)).references == 1)
        }
    }

    @Test("all CommonMark inline raw HTML forms are opaque during reference association")
    func inlineRawHTMLOpacity() {
        let labels = [
            #"outer <x attr="> ["> tail"#,
            #"outer <x a="["> tail"#,
            "outer <x\ta=\"[\"> tail",
            "outer <x\na=\"[\"> tail",
            "outer <x\r\na=\"[\"> tail",
            "outer <x\ra=\"[\"> tail",
            "outer </x> tail",
            "outer <!-- [opaque] --> tail",
            "outer <?test [opaque] ?> tail",
            "outer <!DOCTYPE [opaque]> tail",
            "outer <![CDATA[ [opaque] ]]> tail",
        ]

        for label in labels {
            let source = "[\(label)][ref]\n\n[ref]: /uri\n"
            #expect(linkCounts(in: DocumentAST.parse(source)).references == 1)
            #expect(MarkdownHTMLRenderer.html(from: source)
                .replacingOccurrences(of: "\n</p>", with: "</p>")
                == "<p><a href=\"/uri\">\(escapedHTML(label))</a></p>")
            #expect(MarkdownTextProjection.make(markdown: source).string == "\(label)\n\n")

            let accessibility = MarkdownAccessibilityProjection.make(markdown: source)
            #expect(accessibility.text.string == "\(label)\n\n")
            #expect(accessibility.spans.contains {
                $0.role == .link(destination: "/uri")
                    && $0.visibleRange == NSRange(location: 0, length: (label as NSString).length)
            })

            let styled = MarkdownRendering.attributedString(
                for: source,
                fontName: NSFont.systemFont(ofSize: 16).fontName,
                fontSize: 16
            )
            #expect(styled.attribute(.link, at: 1, effectiveRange: nil) != nil)
            #expect(styled.attribute(.link, at: (label as NSString).length, effectiveRange: nil) != nil)
        }

        for malformed in [
            "outer <!-- [opaque tail",
            "outer <?test [opaque tail",
            "outer <![CDATA[ [opaque tail",
        ] {
            let source = "[\(malformed)][ref]\n\n[ref]: /uri\n"
            #expect(!MarkdownHTMLRenderer.html(from: source)
                .hasPrefix("<p><a href=\"/uri\">outer"))
        }

        for invalidWhitespace in ["\u{00A0}", "\u{000B}"] {
            let labelPrefix = "[outer <x\(invalidWhitespace)a="
            let source = "\(labelPrefix)[> tail][ref]\n\n[ref]: /uri\n"
            #expect(linkCounts(in: DocumentAST.parse(source)).references == 1)
            #expect(MarkdownHTMLRenderer.html(from: source)
                .hasPrefix("<p>\(escapedHTML(labelPrefix))<a href=\"/uri\">&gt; tail</a>"))
            #expect(MarkdownTextProjection.make(markdown: source).string
                == "\(labelPrefix)> tail\n\n")

            let accessibility = MarkdownAccessibilityProjection.make(markdown: source)
            #expect(accessibility.text.string == "\(labelPrefix)> tail\n\n")
            #expect(accessibility.spans.contains {
                $0.role == .link(destination: "/uri")
                    && $0.visibleRange == NSRange(
                        location: (labelPrefix as NSString).length,
                        length: 6
                    )
            })

            let styled = MarkdownRendering.attributedString(
                for: source,
                fontName: NSFont.systemFont(ofSize: 16).fontName,
                fontSize: 16
            )
            #expect(styled.attribute(.link, at: 1, effectiveRange: nil) == nil)
            #expect(styled.attribute(
                .link,
                at: (source as NSString).range(of: "> tail").location,
                effectiveRange: nil
            ) != nil)
        }
    }

    @Test("unclosed raw HTML terminators are searched once per form")
    func malformedRawHTMLOperationBound() {
        let comments = Array(repeating: "<!--", count: 128).joined()
        #expect(InlineParser.rawHTMLTerminatorSearchCount(in: comments) == 1)

        let processingInstructions = Array(repeating: "<?", count: 128).joined()
        #expect(InlineParser.rawHTMLTerminatorSearchCount(in: processingInstructions) == 1)

        let cdata = Array(repeating: "<![CDATA[", count: 128).joined()
        #expect(InlineParser.rawHTMLTerminatorSearchCount(in: cdata) == 1)
    }

    @Test("CommonMark 604/605 email autolinks share HTML, styling and accessibility destinations")
    func semanticAutolinkDestinations() {
        let cases = [
            ("<foo@bar.example.com>", "foo@bar.example.com", "mailto:foo@bar.example.com"),
            ("<foo+special@Bar.baz-bar0.com>", "foo+special@Bar.baz-bar0.com", "mailto:foo+special@Bar.baz-bar0.com"),
            ("<mailto:foo@example.com>", "mailto:foo@example.com", "mailto:foo@example.com"),
            ("<https://example.com>", "https://example.com", "https://example.com"),
        ]

        for (source, label, destination) in cases {
            #expect(MarkdownHTMLRenderer.html(from: source)
                == "<p><a href=\"\(destination)\">\(label)</a></p>")
            #expect(MarkdownTextProjection.make(markdown: source).string == label)
            let accessibility = MarkdownAccessibilityProjection.make(markdown: source)
            #expect(accessibility.text.string == label)
            #expect(accessibility.spans.contains { $0.role == .link(destination: destination) })

            let styled = MarkdownRendering.attributedString(
                for: source,
                fontName: NSFont.systemFont(ofSize: 16).fontName,
                fontSize: 16
            )
            let labelRange = (source as NSString).range(of: label)
            #expect((styled.attribute(.link, at: labelRange.location, effectiveRange: nil) as? URL)?.absoluteString
                == destination)
        }

        let bare = "mail foo@example.com"
        #expect(MarkdownHTMLRenderer.html(from: bare).contains("href=\"mailto:foo@example.com\""))
        let styledBare = MarkdownRendering.attributedString(
            for: bare,
            fontName: NSFont.systemFont(ofSize: 16).fontName,
            fontSize: 16
        )
        let email = (bare as NSString).range(of: "foo@example.com")
        #expect((styledBare.attribute(.link, at: email.location, effectiveRange: nil) as? URL)?.absoluteString
            == "mailto:foo@example.com")
    }

    @Test("reference definition changes invalidate token association caches")
    func definitionChangesInvalidateTokenCaches() {
        let unresolved = "![foo][bar]\n"
        let resolved = unresolved + "\n[bar]: /url\n"

        #expect(MarkdownTokenizer.parseTokensViaAST(in: unresolved).allSatisfy { $0.kind != .imageLink })
        #expect(MarkdownTokenizer.parseTokensViaAST(in: resolved).contains { $0.kind == .imageLink })
        #expect(MarkdownTokenizer.parseTokensViaAST(in: unresolved).allSatisfy { $0.kind != .imageLink })

        let state = DocumentParseState()
        #expect(state.tokens(for: unresolved, edit: nil).allSatisfy { $0.kind != .imageLink })
        #expect(state.tokens(for: resolved, edit: nil).contains { $0.kind == .imageLink })
        #expect(state.tokens(for: unresolved, edit: nil).allSatisfy { $0.kind != .imageLink })
    }

    @Test("reference definitions resolve inside stripped blockquote content")
    func blockquoteReferences() {
        let source = "> [foo][ref]\n\n[ref]: /uri \"title\"\n"
        #expect(MarkdownHTMLRenderer.html(from: source)
            == "<blockquote><a href=\"/uri\" title=\"title\">foo</a></blockquote>")
    }

    private func semanticInlines(in blocks: [BlockNode]) -> (links: Int, images: Int) {
        var links = 0
        var images = 0
        func visit(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .link(_, _, _, _, _, let children):
                    links += 1
                    visit(children)
                case .referenceLink(_, _, _, _, let children):
                    links += 1
                    visit(children)
                case .image:
                    images += 1
                case .referenceImage(_, _, _, _, let children):
                    images += 1
                    visit(children)
                case .emphasis(_, _, _, let children):
                    visit(children)
                case .ext(let node):
                    visit(node.children)
                default:
                    break
                }
            }
        }
        for block in blocks {
            switch block {
            case .paragraph(_, let nodes), .heading(_, _, _, let nodes):
                visit(nodes)
            default:
                break
            }
        }
        return (links, images)
    }

    private func linkCounts(in blocks: [BlockNode]) -> (references: Int, autolinks: Int) {
        var references = 0
        var autolinks = 0
        func visit(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .referenceLink(_, _, _, _, let children):
                    references += 1
                    visit(children)
                case .autolink:
                    autolinks += 1
                case .emphasis(_, _, _, let children):
                    visit(children)
                case .ext(let node):
                    visit(node.children)
                default:
                    break
                }
            }
        }
        for block in blocks {
            if case .paragraph(_, let nodes) = block { visit(nodes) }
        }
        return (references, autolinks)
    }

    private func escapedHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

}

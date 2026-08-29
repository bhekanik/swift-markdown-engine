//
//  InlineParserTests.swift
//  MarkdownEngineTests
//
//  Phase 2 — test-first specification of the inline parser. Ranges are
//  relative to the parsed string.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 2 — inline parser")
struct InlineParserTests {

    private func r(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    @Test("empty string yields no nodes")
    func empty() {
        #expect(InlineParser.parse("") == [])
    }

    @Test("plain text is a single text node")
    func plainText() {
        #expect(InlineParser.parse("hello") == [.text(r(0, 5))])
    }

    @Test("a code span splits the surrounding text")
    func codeSpan() {
        #expect(InlineParser.parse("a `code` b") == [
            .text(r(0, 2)),
            .code(range: r(2, 6), content: r(3, 4)),
            .text(r(8, 2)),
        ])
    }

    @Test("an unclosed backtick run stays literal text")
    func unclosedBacktick() {
        #expect(InlineParser.parse("a `b") == [.text(r(0, 4))])
    }

    // MARK: - Emphasis (asterisks)

    @Test("single asterisks → italic")
    func italic() {
        #expect(InlineParser.parse("*x*") == [
            .emphasis(.italic, range: r(0, 3), markers: [r(0, 1), r(2, 1)], children: [.text(r(1, 1))]),
        ])
    }

    @Test("double asterisks → bold")
    func bold() {
        #expect(InlineParser.parse("**x**") == [
            .emphasis(.bold, range: r(0, 5), markers: [r(0, 2), r(3, 2)], children: [.text(r(2, 1))]),
        ])
    }

    @Test("triple asterisks → bold+italic")
    func boldItalic() {
        #expect(InlineParser.parse("***x***") == [
            .emphasis(.boldItalic, range: r(0, 7), markers: [r(0, 3), r(4, 3)], children: [.text(r(3, 1))]),
        ])
    }

    @Test("nested emphasis builds a tree")
    func nestedEmphasis() {
        #expect(InlineParser.parse("**a *b* c**") == [
            .emphasis(.bold, range: r(0, 11), markers: [r(0, 2), r(9, 2)], children: [
                .text(r(2, 2)),
                .emphasis(.italic, range: r(4, 3), markers: [r(4, 1), r(6, 1)], children: [.text(r(5, 1))]),
                .text(r(7, 2)),
            ]),
        ])
    }

    @Test("intraword asterisks still emphasize")
    func intrawordAsterisk() {
        #expect(InlineParser.parse("a*b*c") == [
            .text(r(0, 1)),
            .emphasis(.italic, range: r(1, 3), markers: [r(1, 1), r(3, 1)], children: [.text(r(2, 1))]),
            .text(r(4, 1)),
        ])
    }

    // MARK: - Emphasis (underscores)

    @Test("single underscores → italic")
    func underscoreItalic() {
        #expect(InlineParser.parse("_x_") == [
            .emphasis(.italic, range: r(0, 3), markers: [r(0, 1), r(2, 1)], children: [.text(r(1, 1))]),
        ])
    }

    @Test("intraword underscores stay literal (GFM)")
    func intrawordUnderscore() {
        #expect(InlineParser.parse("a_b_c") == [.text(r(0, 5))])
    }

    // MARK: - Emphasis × code-span precedence

    @Test("emphasis wraps a code span")
    func emphasisWrapsCode() {
        #expect(InlineParser.parse("*a `c` b*") == [
            .emphasis(.italic, range: r(0, 9), markers: [r(0, 1), r(8, 1)], children: [
                .text(r(1, 2)),
                .code(range: r(3, 3), content: r(4, 1)),
                .text(r(6, 2)),
            ]),
        ])
    }

    @Test("delimiters inside a code span are ignored")
    func delimitersInsideCodeIgnored() {
        #expect(InlineParser.parse("`*x*`") == [.code(range: r(0, 5), content: r(1, 3))])
    }

    // MARK: - Links & images

    @Test("markdown link, text recursively parsed")
    func markdownLink() {
        #expect(InlineParser.parse("[text](url)") == [
            .link(range: r(0, 11), textRange: r(1, 4), url: r(7, 3), title: nil,
                  markers: [r(0, 1), r(5, 1), r(6, 1), r(10, 1)], children: [.text(r(1, 4))]),
        ])
    }

    @Test("markdown link permits inline code inside its label")
    func linkContainsInlineCode() {
        #expect(InlineParser.parse("[`App`](/tmp/App.swift:56)") == [
            .link(
                range: r(0, 26),
                textRange: r(1, 5),
                url: r(8, 17),
                title: nil,
                markers: [r(0, 1), r(6, 1), r(7, 1), r(25, 1)],
                children: [.code(range: r(1, 5), content: r(2, 3))]
            ),
        ])
    }

    @Test("markdown link permits multiple inline code spans in its label")
    func linkContainsMultipleInlineCodeSpans() {
        #expect(InlineParser.parse("[`a` and `b`](u)") == [
            .link(
                range: r(0, 16),
                textRange: r(1, 11),
                url: r(14, 1),
                title: nil,
                markers: [r(0, 1), r(12, 1), r(13, 1), r(15, 1)],
                children: [
                    .code(range: r(1, 3), content: r(2, 1)),
                    .text(r(4, 5)),
                    .code(range: r(9, 3), content: r(10, 1)),
                ]
            ),
        ])
    }

    @Test("claimed span crossing a link-label boundary rejects the link")
    func codeCrossingLinkLabelBoundaryRejectsLink() {
        #expect(InlineParser.parse("[a `b](u)`") == [
            .text(r(0, 3)),
            .code(range: r(3, 7), content: r(4, 5)),
        ])
    }

    @Test("markdown link permits escaped punctuation inside its label")
    func linkContainsEscapedPunctuation() {
        #expect(InlineParser.parse(#"[\*](u)"#) == [
            .link(
                range: r(0, 7),
                textRange: r(1, 2),
                url: r(5, 1),
                title: nil,
                markers: [r(0, 1), r(3, 1), r(4, 1), r(6, 1)],
                children: [.escape(range: r(1, 2), character: r(2, 1), marker: r(1, 1))]
            ),
        ])
    }

    @Test("markdown-looking text inside code remains inert")
    func codeContainingLinkStaysOpaque() {
        #expect(InlineParser.parse("`[a](b)`") == [
            .code(range: r(0, 8), content: r(1, 6)),
        ])
    }

    @Test("link URL keeps balanced parentheses (bug 4)")
    func linkWithBalancedParens() {
        #expect(InlineParser.parse("[a](b(c))") == [
            .link(range: r(0, 9), textRange: r(1, 1), url: r(4, 4), title: nil,
                  markers: [r(0, 1), r(2, 1), r(3, 1), r(8, 1)], children: [.text(r(1, 1))]),
        ])
    }

    @Test("image")
    func image() {
        #expect(InlineParser.parse("![alt](u)") == [
            .image(range: r(0, 9), alt: r(2, 3), url: r(7, 1), title: nil, markers: [r(0, 2), r(5, 1), r(6, 1), r(8, 1)]),
        ])
    }

    @Test("image descriptions admit punctuation escapes and preserve source ranges")
    func escapedImageDescriptions() throws {
        let cases: [(source: String, label: String)] = [
            (#"![escaped\*alt](image.png)"#, "escaped*alt"),
            (#"![escaped\]alt](image.png)"#, "escaped]alt"),
            (#"![slash\\](image.png)"#, #"slash\"#),
        ]

        for entry in cases {
            let node = try #require(InlineParser.parse(entry.source).first)
            guard case .image(let range, let alt, _, _, _) = node else {
                Issue.record("Expected image for \(entry.source)")
                continue
            }
            let ns = entry.source as NSString
            #expect(ns.substring(with: range) == entry.source)
            #expect(MarkdownLinkSyntax.unescapedText(in: ns, range: alt) == entry.label)
        }

        for malformed in [#"![escaped\]alt](image.png"#, #"![escaped\]alt(image.png)"#] {
            #expect(InlineParser.parse(malformed).allSatisfy {
                if case .image = $0 { return false }
                return true
            })
        }
    }

    @Test("emphasis inside link text")
    func linkContainsEmphasis() {
        #expect(InlineParser.parse("[*x*](u)") == [
            .link(range: r(0, 8), textRange: r(1, 3), url: r(6, 1), title: nil,
                  markers: [r(0, 1), r(4, 1), r(5, 1), r(7, 1)],
                  children: [.emphasis(.italic, range: r(1, 3), markers: [r(1, 1), r(3, 1)], children: [.text(r(2, 1))])]),
        ])
    }

    @Test("emphasis wraps a link")
    func emphasisWrapsLink() {
        #expect(InlineParser.parse("*[a](b)*") == [
            .emphasis(.italic, range: r(0, 8), markers: [r(0, 1), r(7, 1)], children: [
                .link(range: r(1, 6), textRange: r(2, 1), url: r(5, 1), title: nil,
                      markers: [r(1, 1), r(3, 1), r(4, 1), r(6, 1)], children: [.text(r(2, 1))]),
            ]),
        ])
    }

    @Test("link and image destinations split from quoted titles; angle brackets are markers")
    func linkAndImageTitles() throws {
        for source in [
            #"[text](url "title")"#,
            #"[text](url 'title')"#,
            #"[text](url (title))"#,
        ] {
            let node = try #require(InlineParser.parse(source).first)
            guard case .link(_, _, let url, let title, _, _) = node else {
                Issue.record("Expected link for \(source)")
                continue
            }
            let ns = source as NSString
            #expect(ns.substring(with: url) == "url")
            #expect(title.map { ns.substring(with: $0) } == "title")
        }

        let source = #"![alt](<https://example.com/a.png> "caption")"#
        let node = try #require(InlineParser.parse(source).first)
        guard case .image(_, _, let url, let title, let markers) = node else {
            Issue.record("Expected image")
            return
        }
        let ns = source as NSString
        #expect(ns.substring(with: url) == "https://example.com/a.png")
        #expect(title.map { ns.substring(with: $0) } == "caption")
        #expect(markers.contains { ns.substring(with: $0) == "<" })
        #expect(markers.contains { ns.substring(with: $0) == ">" })

        #expect(InlineParser.parse("[text]()") == [
            .link(
                range: r(0, 8), textRange: r(1, 4), url: r(7, 0), title: nil,
                markers: [r(0, 1), r(5, 1), r(6, 1), r(7, 1)], children: [.text(r(1, 4))]
            ),
        ])
    }

    @Test("link destinations and titles honor CommonMark punctuation escapes")
    func escapedLinkTargets() throws {
        let cases: [(source: String, destination: String, title: String?, image: Bool)] = [
            (#"[angle](<https://example.com/a\>b> "ti\*tle")"#, "https://example.com/a>b", "ti*tle", false),
            (#"[paren](https://example.com/a\)b 'ti\'tle')"#, "https://example.com/a)b", "ti'tle", false),
            (#"[official](/bar\* "ti\*tle")"#, "/bar*", "ti*tle", false),
            (#"![image](<https://example.com/a\>b>)"#, "https://example.com/a>b", nil, true),
            (#"[slash](path\\)"#, #"path\"#, nil, false),
        ]

        for entry in cases {
            let node = try #require(InlineParser.parse(entry.source).first)
            let ns = entry.source as NSString
            let range: NSRange
            let destination: NSRange
            let title: NSRange?
            switch node {
            case .link(let nodeRange, _, let url, let nodeTitle, _, _):
                #expect(entry.image == false)
                range = nodeRange
                destination = url
                title = nodeTitle
            case .image(let nodeRange, _, let url, let nodeTitle, _):
                #expect(entry.image)
                range = nodeRange
                destination = url
                title = nodeTitle
            default:
                Issue.record("Expected link or image for \(entry.source)")
                continue
            }
            #expect(ns.substring(with: range) == entry.source)
            #expect(MarkdownLinkSyntax.unescapedText(in: ns, range: destination)
                == entry.destination)
            #expect(title.map { MarkdownLinkSyntax.unescapedText(in: ns, range: $0) }
                == entry.title)
        }

        for malformed in [#"[x](<a\>)"#, #"[x](a\)"#, #"[x](<a<b>)"#] {
            #expect(InlineParser.parse(malformed).allSatisfy { node in
                if case .link = node { return false }
                if case .image = node { return false }
                return true
            })
        }
    }

    @Test("bare destinations do not escape whitespace or ASCII controls")
    func invalidBareDestinationEscapes() {
        let invalid = [
            #"[x](https://example.com/a\ b)"#,
            #"[x](https://example.com/a\\ b)"#,
            "[x](https://example.com/a\\\nb)",
            "[x](https://example.com/a\\\\\nb)",
            #"![x](https://example.com/a\ b)"#,
        ] + LinkDestinationTestFixtures.invalidBareControlLinks
            + LinkDestinationTestFixtures.invalidBareControlImages

        for source in invalid {
            #expect(InlineParser.parse(source).allSatisfy { node in
                if case .link = node { return false }
                if case .image = node { return false }
                return true
            }, "Unexpected active target in \(source.debugDescription)")
        }
    }

    @Test("full, collapsed, and shortcut reference links preserve their label shape")
    func referenceLinks() {
        #expect(InlineParser.parse("[text][ID]", referenceDefinitions: ["id"]) == [
            .referenceLink(
                range: r(0, 10), textRange: r(1, 4), label: r(7, 2),
                markers: [r(0, 1), r(5, 1), r(6, 1), r(9, 1)], children: [.text(r(1, 4))]
            ),
        ])
        #expect(InlineParser.parse("[text][]", referenceDefinitions: ["text"]) == [
            .referenceLink(
                range: r(0, 8), textRange: r(1, 4), label: nil,
                markers: [r(0, 1), r(5, 1), r(6, 1), r(7, 1)], children: [.text(r(1, 4))]
            ),
        ])
        #expect(InlineParser.parse("[ID]", referenceDefinitions: ["id"]) == [
            .referenceLink(
                range: r(0, 4), textRange: r(1, 2), label: nil,
                markers: [r(0, 1), r(3, 1)], children: [.text(r(1, 2))]
            ),
        ])
    }

    @Test("explicit reference labels admit escapes without decoding normalization")
    func escapedReferenceLabels() throws {
        let source = #"[foo][ref\[]"#
        let node = try #require(InlineParser.parse(
            source,
            referenceDefinitions: [#"ref\["#]
        ).first)
        guard case let .referenceLink(_, textRange, label, _, _) = node else {
            Issue.record("Expected reference link")
            return
        }
        let ns = source as NSString
        #expect(ns.substring(with: textRange) == "foo")
        #expect(label.map { ns.substring(with: $0) } == #"ref\["#)
        #expect(label.map { MarkdownLinkSyntax.normalizedLabel(in: ns, range: $0) } == #"ref\["#)

        for invalid in ["[foo][ref[]", #"[foo][ref\\[]"#] {
            #expect(InlineParser.parse(
                invalid,
                referenceDefinitions: [#"ref\["#]
            ).allSatisfy {
                if case .referenceLink = $0 { return false }
                return true
            })
        }
    }

    @Test("extension spans keep their brackets out of reference association")
    func extensionBracketsDoNotCloseLinks() {
        let registry = ExtensionRegistry(extensions: [HighlightExtension()])
        let opaque = InlineParser.parse(
            "[foo ==][ref]==",
            registry: registry,
            referenceDefinitions: ["ref"]
        )
        #expect(opaque.allSatisfy {
            if case .referenceLink = $0 { return false }
            return true
        })
        #expect(opaque.contains {
            if case .ext = $0 { return true }
            return false
        })

        let contained = InlineParser.parse(
            "[foo ==bar==][ref]",
            registry: registry,
            referenceDefinitions: ["ref"]
        )
        #expect(contained.count == 1)
        guard case .referenceLink(_, _, _, _, let children) = contained[0] else {
            Issue.record("Expected reference link")
            return
        }
        #expect(children.contains {
            if case .ext = $0 { return true }
            return false
        })
    }

    @Test("footnote references claim the whole bracket run")
    func footnoteReference() {
        #expect(InlineParser.parse("[^note]") == [
            .footnoteReference(range: r(0, 7), label: r(2, 4), markers: [r(0, 2), r(6, 1)]),
        ])
    }

    @Test("hard-break markers claim only internal-line backslashes and trailing spaces")
    func hardBreakMarkers() {
        let nodes = InlineParser.parse("a  \nb\\\nc  ")
        #expect(nodes.contains { $0 == .hardBreak(range: r(1, 3), marker: r(1, 2)) })
        #expect(nodes.contains { $0 == .hardBreak(range: r(5, 2), marker: r(5, 1)) })
        #expect(!nodes.contains { node in
            if case .hardBreak(let range, _) = node { return range.location >= 8 }
            return false
        })
        #expect(InlineParser.parse("`a\\\nb`").allSatisfy {
            if case .hardBreak = $0 { return false }
            return true
        })
    }

    @Test("autolinks claim valid URI and email brackets but leave HTML and comparisons literal")
    func autolinks() throws {
        for source in ["<https://example.com>", "<mailto:someone@example.com>", "<someone@example.com>"] {
            let node = try #require(InlineParser.parse(source).first)
            guard case .autolink(let range, let url, let markers) = node else {
                Issue.record("Expected autolink for \(source)")
                continue
            }
            let length = (source as NSString).length
            #expect(range == r(0, length))
            #expect(markers == [r(0, 1), r(length - 1, 1)])
            #expect((source as NSString).substring(with: url) == String(source.dropFirst().dropLast()))
        }
        #expect(InlineParser.parse("a < b") == [.text(r(0, 5))])
        #expect(InlineParser.parse("<span>") == [.text(r(0, 6))])

        let escaped = #"<https://example.com/\[\>"#
        guard case .autolink(_, let url, _) = try #require(InlineParser.parse(escaped).first) else {
            Issue.record("Expected escaped punctuation to remain inside an autolink")
            return
        }
        #expect((escaped as NSString).substring(with: url) == #"https://example.com/\[\"#)
    }

    // MARK: - Strikethrough (extension-supplied `~~…~~` span)

    private var strikeRegistry: ExtensionRegistry {
        ExtensionRegistry(extensions: [StrikethroughExtension()])
    }

    private func strike(range: NSRange, markers: [NSRange], children: [InlineNode]) -> InlineNode {
        .ext(ExtensionInlineNode(
            extensionID: StrikethroughExtension.identifier,
            range: range,
            contentRange: NSRange(location: NSMaxRange(markers[0]),
                                  length: markers[1].location - NSMaxRange(markers[0])),
            markers: markers, children: children))
    }

    @Test("without a registered extension, ~~x~~ stays literal text")
    func strikethroughUnregisteredStaysLiteral() {
        #expect(InlineParser.parse("~~x~~") == [.text(r(0, 5))])
    }

    @Test("strikethrough, content recursively parsed")
    func strikethrough() {
        #expect(InlineParser.parse("~~x~~", registry: strikeRegistry) == [
            strike(range: r(0, 5), markers: [r(0, 2), r(3, 2)], children: [.text(r(2, 1))]),
        ])
    }

    @Test("triple tildes do not strike")
    func tripleTildeNotStrike() {
        #expect(InlineParser.parse("~~~x~~~", registry: strikeRegistry) == [.text(r(0, 7))])
    }

    @Test("~~abc~~~ stays literal (closer must not extend a longer run)")
    func strikethroughRejectsCloserRun() {
        #expect(InlineParser.parse("~~abc~~~", registry: strikeRegistry) == [.text(r(0, 8))])
    }

    @Test("strikethrough wraps emphasis")
    func strikeWrapsEmphasis() {
        #expect(InlineParser.parse("~~*x*~~", registry: strikeRegistry) == [
            strike(range: r(0, 7), markers: [r(0, 2), r(5, 2)], children: [
                .emphasis(.italic, range: r(2, 3), markers: [r(2, 1), r(4, 1)], children: [.text(r(3, 1))]),
            ]),
        ])
    }

    @Test("both extensions registered: ~~ and == coexist and nest")
    func strikeAndHighlightCoexist() {
        let registry = ExtensionRegistry(extensions: [HighlightExtension(), StrikethroughExtension()])
        let nodes = InlineParser.parse("~~a~~ ==b==", registry: registry)
        #expect(nodes.count == 3)   // strike, " ", highlight
        if case .ext(let first) = nodes[0] { #expect(first.extensionID == StrikethroughExtension.identifier) }
        if case .ext(let last) = nodes[2] { #expect(last.extensionID == HighlightExtension.identifier) }
    }

    // MARK: - Highlight (extension-supplied `==…==` span)

    private var highlightRegistry: ExtensionRegistry {
        ExtensionRegistry(extensions: [HighlightExtension()])
    }

    private func hi(range: NSRange, markers: [NSRange], children: [InlineNode]) -> InlineNode {
        .ext(ExtensionInlineNode(
            extensionID: HighlightExtension.identifier,
            range: range,
            contentRange: NSRange(location: NSMaxRange(markers[0]),
                                  length: markers[1].location - NSMaxRange(markers[0])),
            markers: markers, children: children))
    }

    @Test("without a registered extension, ==x== stays literal text")
    func highlightUnregisteredStaysLiteral() {
        #expect(InlineParser.parse("==x==") == [.text(r(0, 5))])
    }

    @Test("highlight, content recursively parsed")
    func highlight() {
        #expect(InlineParser.parse("==x==", registry: highlightRegistry) == [
            hi(range: r(0, 5), markers: [r(0, 2), r(3, 2)], children: [.text(r(2, 1))]),
        ])
    }

    @Test("triple equals do not highlight")
    func tripleEqualsNotHighlight() {
        #expect(InlineParser.parse("===x===", registry: highlightRegistry) == [.text(r(0, 7))])
    }

    @Test("==abc=== matches ==abc==, trailing = is plain text")
    func highlightToleratesTrailingTripleEquals() {
        #expect(InlineParser.parse("==abc===", registry: highlightRegistry) == [
            hi(range: r(0, 7), markers: [r(0, 2), r(5, 2)], children: [.text(r(2, 3))]),
            .text(r(7, 1)),
        ])
    }

    @Test("highlight wraps emphasis")
    func highlightWrapsEmphasis() {
        #expect(InlineParser.parse("==*x*==", registry: highlightRegistry) == [
            hi(range: r(0, 7), markers: [r(0, 2), r(5, 2)], children: [
                .emphasis(.italic, range: r(2, 3), markers: [r(2, 1), r(4, 1)], children: [.text(r(3, 1))]),
            ]),
        ])
    }

    @Test("a lone = inside content aborts the highlight candidate")
    func highlightLoneEqualsAborts() {
        #expect(InlineParser.parse("==a=b==", registry: highlightRegistry) == [.text(r(0, 7))])
    }

    @Test("highlight never crosses a code span")
    func highlightDoesNotCrossCodeSpan() {
        // The backtick run is claimed first; the == candidate overlapping it is rejected.
        #expect(InlineParser.parse("==a `b==` c", registry: highlightRegistry) == [
            .text(r(0, 4)),
            .code(range: r(4, 5), content: r(5, 3)),
            .text(r(9, 2)),
        ])
    }

    // MARK: - Backslash escapes

    @Test("escaped punctuation becomes an escape node")
    func backslashEscape() {
        #expect(InlineParser.parse(#"\*x"#) == [
            .escape(range: r(0, 2), character: r(1, 1), marker: r(0, 1)),
            .text(r(2, 1)),
        ])
    }

    @Test("escaped asterisks do not emphasize")
    func escapedStarsNotEmphasis() {
        #expect(InlineParser.parse(#"\*a\*"#) == [
            .escape(range: r(0, 2), character: r(1, 1), marker: r(0, 1)),
            .text(r(2, 1)),
            .escape(range: r(3, 2), character: r(4, 1), marker: r(3, 1)),
        ])
    }

    @Test("backslash inside a code span is literal (no escape)")
    func escapeInsideCodeIgnored() {
        #expect(InlineParser.parse(#"`\*`"#) == [.code(range: r(0, 4), content: r(1, 2))])
    }
}

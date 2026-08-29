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

    @Test("escaped link targets remain hidden across inline, image, and reference forms")
    func projectsEscapedLinkTargets() {
        let source = #"""
[inline](<https://example.com/a\>b>) ![image](https://example.com/a\)b) [reference][id]

[id]: <https://example.com/a\>b> "ti\*tle"
"""#
        let projection = project(source)

        #expect(projection.string == "inline image reference\n\n")
        #expect(!projection.string.contains("example.com"))
    }

    @Test("escaped image descriptions and reference labels preserve visible semantics")
    func projectsEscapedImageDescriptionsAndReferenceLabels() {
        let source = #"""
![escaped\*alt](image.png) ![escaped\]alt](image.png) ![slash\\](image.png)
[foo][ref\[] [bar][foo\!]

[ref\[]: /uri
[foo!]: /wrong
"""#
        let projection = project(source)

        #expect(projection.string == "escaped*alt escaped]alt slash\\\nfoo [bar][foo!]\n\n")
    }

    @Test("invalid bare destination escapes remain literal")
    func projectsInvalidBareDestinationEscapesLiterally() {
        let cases: [(source: String, visible: String)] = [
            (#"[x](https://example.com/a\ b)"#, #"[x](https://example.com/a\ b)"#),
            (#"[x](https://example.com/a\\ b)"#, #"[x](https://example.com/a\ b)"#),
            ("[x](https://example.com/a\\\nb)", "[x](https://example.com/a\nb)"),
            (#"![x](https://example.com/a\ b)"#, #"![x](https://example.com/a\ b)"#),
            ("[id]: /a\\ b\n\n[x][id]", "[id]: /a\\ b\n\n[x][id]"),
        ]

        for entry in cases {
            #expect(project(entry.source).string == entry.visible)
        }
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

    @Test("indexed mappings match the linear reference at every boundary")
    func indexedMappingsMatchLinearReference() {
        let source = "---\ntitle: Hidden\n---\nA **cafe\u{301}** [link](https://secret.example) 👩🏽‍💻\n"
        let projection = project(source)

        for start in 0...projection.sourceUTF16Length {
            for end in start...projection.sourceUTF16Length {
                let range = NSRange(location: start, length: end - start)
                #expect(projection.visibleRange(for: range) == linearVisibleRange(
                    for: range,
                    in: projection
                ))
            }
        }
        for start in 0...projection.visibleUTF16Length {
            for end in start...projection.visibleUTF16Length {
                let range = NSRange(location: start, length: end - start)
                #expect(projection.sourceRange(for: range) == linearSourceRange(
                    for: range,
                    in: projection
                ))
            }
        }
    }

    @Test("ten thousand link mappings stay below the release regression ceiling")
    func largeLinkMappingsStaySublinear() {
        var source = ""
        var sourceRanges: [NSRange] = []
        var visibleRanges: [NSRange] = []
        sourceRanges.reserveCapacity(10_000)
        visibleRanges.reserveCapacity(10_000)
        var sourceOffset = 0
        var visibleOffset = 0
        for index in 0..<10_000 {
            let label = "word\(index)"
            let chunk = "[\(label)](https://secret.example/\(index))"
            sourceRanges.append(NSRange(location: sourceOffset + 1, length: label.utf16.count))
            visibleRanges.append(NSRange(location: visibleOffset, length: label.utf16.count))
            source += chunk
            sourceOffset += chunk.utf16.count
            visibleOffset += label.utf16.count
            if index < 9_999 {
                source += " "
                sourceOffset += 1
                visibleOffset += 1
            }
        }
        let projection = project(source)
        var checksum = 0
        let start = ContinuousClock.now
        for index in 0..<10_000 {
            checksum &+= projection.visibleRange(for: sourceRanges[index])?.location ?? 0
            checksum &+= projection.sourceRange(for: visibleRanges[index])?.location ?? 0
        }
        let elapsed = start.duration(to: .now)
        print("10k bidirectional projection mappings: \(elapsed)")
        #expect(checksum > 0)
#if !DEBUG
        #expect(elapsed < .seconds(2), "10k bidirectional mappings took \(elapsed)")
#endif
    }

    private func linearSourceRange(
        for visibleRange: NSRange,
        in projection: MarkdownTextProjection
    ) -> NSRange? {
        if visibleRange.length == 0 {
            for span in projection.spans {
                if visibleRange.location < NSMaxRange(span.visibleRange) {
                    let delta = max(visibleRange.location, span.visibleRange.location)
                        - span.visibleRange.location
                    let source = span.sourceRange.length == span.visibleRange.length
                        ? span.sourceRange.location + delta
                        : span.sourceRange.location
                    return NSRange(location: source, length: 0)
                }
            }
            return NSRange(location: projection.sourceUTF16Length, length: 0)
        }
        let end = NSMaxRange(visibleRange)
        guard let first = projection.spans.first(where: {
            NSLocationInRange(visibleRange.location, $0.visibleRange)
        }), let last = projection.spans.last(where: {
            NSLocationInRange(end - 1, $0.visibleRange)
        }) else { return nil }
        let startDelta = visibleRange.location - first.visibleRange.location
        let endDelta = end - last.visibleRange.location
        let sourceStart = first.sourceRange.length == first.visibleRange.length
            ? first.sourceRange.location + startDelta
            : first.sourceRange.location
        let sourceEnd = last.sourceRange.length == last.visibleRange.length
            ? last.sourceRange.location + endDelta
            : NSMaxRange(last.sourceRange)
        return NSRange(location: sourceStart, length: sourceEnd - sourceStart)
    }

    private func linearVisibleRange(
        for sourceRange: NSRange,
        in projection: MarkdownTextProjection
    ) -> NSRange? {
        if sourceRange.length == 0 {
            for span in projection.spans {
                if sourceRange.location < NSMaxRange(span.sourceRange) {
                    let delta = max(sourceRange.location, span.sourceRange.location)
                        - span.sourceRange.location
                    let visible = span.sourceRange.length == span.visibleRange.length
                        ? span.visibleRange.location + delta
                        : span.visibleRange.location
                    return NSRange(location: visible, length: 0)
                }
            }
            return NSRange(location: projection.visibleUTF16Length, length: 0)
        }
        let intersecting = projection.spans.filter {
            NSIntersectionRange($0.sourceRange, sourceRange).length > 0
        }
        guard let first = intersecting.first, let last = intersecting.last else {
            return linearVisibleRange(
                for: NSRange(location: sourceRange.location, length: 0),
                in: projection
            )
        }
        let sourceEnd = NSMaxRange(sourceRange)
        let startDelta = max(sourceRange.location, first.sourceRange.location)
            - first.sourceRange.location
        let endDelta = min(sourceEnd, NSMaxRange(last.sourceRange))
            - last.sourceRange.location
        let visibleStart = first.sourceRange.length == first.visibleRange.length
            ? first.visibleRange.location + startDelta
            : first.visibleRange.location
        let visibleEnd = last.sourceRange.length == last.visibleRange.length
            ? last.visibleRange.location + endDelta
            : NSMaxRange(last.visibleRange)
        return NSRange(location: visibleStart, length: visibleEnd - visibleStart)
    }
}

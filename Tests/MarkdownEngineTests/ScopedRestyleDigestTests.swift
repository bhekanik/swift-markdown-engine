import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Scoped restyle digest")
struct ScopedRestyleDigestTests {
    private var fontName: String { NSFont.systemFont(ofSize: 16).fontName }

    private func document(paragraphs: Int) -> String {
        (0..<paragraphs).map { index in
            if index == paragraphs / 2 {
                return "## Edited **paragraph** with *emphasis* and a [link](https://example.com)."
            }
            if index.isMultiple(of: 10) {
                return "### Heading \(index)"
            }
            if index.isMultiple(of: 3) {
                return "- List item \(index) with **bold** text"
            }
            return "Ordinary paragraph \(index) with *emphasis* and a [link](https://example.com)."
        }
        .joined(separator: "\n\n")
    }

    private func editedParagraph(in text: String) -> NSRange {
        let ns = text as NSString
        return ns.paragraphRange(for: ns.range(of: "## Edited"))
    }

    private func styleScoped(_ text: String) -> [StyledRange] {
        MarkdownASTStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: 16,
            scopedRanges: [editedParagraph(in: text)]
        )
    }

    @Test("scoped restyle produces identical attributes regardless of document size")
    func scopedWorkIsIdenticalRegardlessOfDocumentSize() {
        func digest(_ text: String) -> String {
            let paragraph = editedParagraph(in: text)
            return styleScoped(text)
                .filter { NSIntersectionRange($0.range, paragraph).length > 0 }
                .map { entry in
                    let offset = entry.range.location - paragraph.location
                    let keys = entry.attributes.keys.map(\.rawValue).sorted().joined(separator: ",")
                    let size = (entry.attributes[.font] as? NSFont).map { "\($0.pointSize)" } ?? "-"
                    return "\(offset):\(entry.range.length)[\(keys)]\(size)"
                }
                .sorted()
                .joined(separator: "\n")
        }

        #expect(digest(document(paragraphs: 40)) == digest(document(paragraphs: 400)))
    }
}

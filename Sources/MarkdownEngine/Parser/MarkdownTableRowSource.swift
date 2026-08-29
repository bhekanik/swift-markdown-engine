import Foundation

/// GFM resolves escaped table delimiters before parsing a cell's inline Markdown.
/// This keeps that normalized text tied to its original UTF-16 source ranges.
struct MarkdownTableRowSource {
    struct Cell {
        let sourceRange: NSRange
        let normalizedText: String
        let escapedPipeMarkers: [NSRange]
        private let markerOffsets: [Int]

        fileprivate init(
            source: NSString,
            range: NSRange,
            escapedPipeMarkers: [NSRange]
        ) {
            sourceRange = range
            self.escapedPipeMarkers = escapedPipeMarkers

            var parts: [String] = []
            parts.reserveCapacity(escapedPipeMarkers.count + 1)
            var sourceCursor = range.location
            for marker in escapedPipeMarkers {
                if marker.location > sourceCursor {
                    parts.append(source.substring(with: NSRange(
                        location: sourceCursor,
                        length: marker.location - sourceCursor
                    )))
                }
                sourceCursor = NSMaxRange(marker)
            }
            if sourceCursor < NSMaxRange(range) {
                parts.append(source.substring(with: NSRange(
                    location: sourceCursor,
                    length: NSMaxRange(range) - sourceCursor
                )))
            }
            normalizedText = parts.joined()
            markerOffsets = escapedPipeMarkers.enumerated().map { index, marker in
                marker.location - range.location - index
            }
        }

        func sourceRange(forNormalizedRange range: NSRange) -> NSRange? {
            let normalizedLength = (normalizedText as NSString).length
            guard range.location != NSNotFound,
                  range.location >= 0,
                  range.length >= 0,
                  range.location <= normalizedLength,
                  range.length <= normalizedLength - range.location else { return nil }

            let end = NSMaxRange(range)
            let start = sourceRange.location + range.location
                + markerCount(before: range.location, includingBoundary: true)
            if range.length == 0 {
                return NSRange(location: start, length: 0)
            }
            let sourceEnd = sourceRange.location + end
                + markerCount(before: end, includingBoundary: false)
            return NSRange(location: start, length: sourceEnd - start)
        }

        private func markerCount(before boundary: Int, includingBoundary: Bool) -> Int {
            var lower = 0
            var upper = markerOffsets.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let precedesBoundary = markerOffsets[middle] < boundary
                    || (includingBoundary && markerOffsets[middle] == boundary)
                if precedesBoundary {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        func inlineNodes(
            registry: ExtensionRegistry,
            referenceDefinitions: Set<String>
        ) -> [InlineNode] {
            MarkdownTableRowSource.inlineNodes(
                in: normalizedText,
                registry: registry,
                referenceDefinitions: referenceDefinitions
            )
        }
    }

    let lineRange: NSRange
    let contentRange: NSRange
    let delimiters: [Int]
    let cells: [Cell]

    static func renderedColumnCount(in rows: [MarkdownTableRowSource]) -> Int? {
        guard rows.count >= 2 else { return nil }
        return max(rows[0].cells.count, rows[1].cells.count)
    }

    static func inlineNodes(
        in normalizedText: String,
        registry: ExtensionRegistry,
        referenceDefinitions: Set<String>
    ) -> [InlineNode] {
        InlineParser.parse(
            normalizedText,
            registry: registry,
            referenceDefinitions: referenceDefinitions
        )
    }

    static func rows(in source: NSString, range: NSRange) -> [MarkdownTableRowSource] {
        let rangeEnd = NSMaxRange(range)
        var rows: [MarkdownTableRowSource] = []
        var cursor = range.location
        while cursor < rangeEnd {
            var ignoredLineStart = 0
            var lineEnd = 0
            var contentEnd = 0
            source.getLineStart(
                &ignoredLineStart,
                end: &lineEnd,
                contentsEnd: &contentEnd,
                for: NSRange(location: cursor, length: 0)
            )
            lineEnd = min(lineEnd, rangeEnd)
            contentEnd = min(contentEnd, lineEnd)
            rows.append(make(
                source: source,
                lineRange: NSRange(location: cursor, length: lineEnd - cursor),
                contentRange: NSRange(location: cursor, length: contentEnd - cursor)
            ))
            guard lineEnd > cursor else { break }
            cursor = lineEnd
        }
        return rows
    }

    static func row(_ line: String) -> MarkdownTableRowSource {
        let source = line as NSString
        let range = NSRange(location: 0, length: source.length)
        return make(source: source, lineRange: range, contentRange: range)
    }

    private static func make(
        source: NSString,
        lineRange: NSRange,
        contentRange: NSRange
    ) -> MarkdownTableRowSource {
        var contentStart = contentRange.location
        var contentEnd = NSMaxRange(contentRange)
        while contentStart < contentEnd,
              isHorizontalWhitespace(source.character(at: contentStart)) {
            contentStart += 1
        }
        while contentEnd > contentStart,
              isHorizontalWhitespace(source.character(at: contentEnd - 1)) {
            contentEnd -= 1
        }

        var delimiters: [Int] = []
        var escapedPipeMarkers: [NSRange] = []
        var escaped = false
        var escapeOffset = 0
        if contentStart < contentEnd {
            for offset in contentStart..<contentEnd {
                let character = source.character(at: offset)
                if escaped {
                    if character == 0x7C {
                        escapedPipeMarkers.append(NSRange(location: escapeOffset, length: 1))
                    }
                    escaped = false
                } else if character == 0x5C {
                    escaped = true
                    escapeOffset = offset
                } else if character == 0x7C {
                    delimiters.append(offset)
                }
            }
        }

        var separators = delimiters
        if separators.first == contentStart {
            contentStart += 1
            separators.removeFirst()
        }
        if separators.last == contentEnd - 1 {
            contentEnd -= 1
            separators.removeLast()
        }

        var cells: [Cell] = []
        var cellStart = contentStart
        var markerIndex = 0
        for cellEnd in separators + [contentEnd] {
            var start = cellStart
            var end = cellEnd
            while start < end, isHorizontalWhitespace(source.character(at: start)) {
                start += 1
            }
            while end > start, isHorizontalWhitespace(source.character(at: end - 1)) {
                end -= 1
            }
            let cellRange = NSRange(location: start, length: end - start)
            while markerIndex < escapedPipeMarkers.count,
                  escapedPipeMarkers[markerIndex].location < start {
                markerIndex += 1
            }
            let firstMarker = markerIndex
            while markerIndex < escapedPipeMarkers.count,
                  NSMaxRange(escapedPipeMarkers[markerIndex]) <= end {
                markerIndex += 1
            }
            cells.append(Cell(
                source: source,
                range: cellRange,
                escapedPipeMarkers: Array(escapedPipeMarkers[firstMarker..<markerIndex])
            ))
            cellStart = cellEnd + 1
        }

        return MarkdownTableRowSource(
            lineRange: lineRange,
            contentRange: contentRange,
            delimiters: delimiters,
            cells: cells
        )
    }

    private static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }
}

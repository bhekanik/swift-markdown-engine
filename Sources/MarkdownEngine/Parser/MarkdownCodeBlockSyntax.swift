import Foundation

enum MarkdownCodeBlockSyntax {
    struct Parts {
        let content: NSRange
        let openFence: NSRange?
        let closeFence: NSRange?
    }

    struct FencedBlock {
        let range: NSRange
        let content: NSRange
        let openFence: NSRange
        let closeFence: NSRange?
    }

    struct IndentedBlock {
        let range: NSRange
        let content: NSRange
    }

    private struct Fence {
        let character: unichar
        let length: Int
        let containers: [Container]
    }

    private enum Container {
        case quote
        case list(indentation: Int)
    }

    static func fencedBlocks(in source: NSString) -> [FencedBlock] {
        var lines: [NSRange] = []
        var cursor = 0
        while cursor < source.length {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
            lines.append(line)
            cursor = NSMaxRange(line)
        }

        var blocks: [FencedBlock] = []
        var lineIndex = 0
        while lineIndex < lines.count {
            let openingLine = lines[lineIndex]
            guard let opening = openingFence(in: source, lineRange: openingLine) else {
                lineIndex += 1
                continue
            }
            var closingIndex: Int?
            var terminationIndex: Int?
            var candidate = lineIndex + 1
            while candidate < lines.count {
                if !continuesContainer(
                    in: source,
                    lineRange: lines[candidate],
                    containers: opening.containers
                ) {
                    terminationIndex = candidate
                    break
                }
                if isClosingFence(in: source, lineRange: lines[candidate], opening: opening) {
                    closingIndex = candidate
                    break
                }
                candidate += 1
            }
            let end = closingIndex.map { NSMaxRange(lines[$0]) }
                ?? terminationIndex.map { lines[$0].location }
                ?? source.length
            let contentEnd = closingIndex.map { lines[$0].location } ?? end
            blocks.append(FencedBlock(
                range: NSRange(location: openingLine.location, length: end - openingLine.location),
                content: NSRange(location: NSMaxRange(openingLine), length: max(0, contentEnd - NSMaxRange(openingLine))),
                openFence: openingLine,
                closeFence: closingIndex.map { lines[$0] }
            ))
            lineIndex = closingIndex.map { $0 + 1 } ?? terminationIndex ?? lines.count
        }
        return blocks
    }

    static func containerIndentedBlocks(
        in source: NSString,
        intersecting scopedRanges: [NSRange]?
    ) -> [IndentedBlock] {
        var lines: [NSRange] = []
        if let scopedRanges {
            var lineLocations: Set<Int> = []
            for scope in scopedRanges where source.length > 0 {
                var cursor = min(scope.location, source.length - 1)
                let finalLocation = min(
                    max(scope.location, NSMaxRange(scope) - 1),
                    source.length - 1
                )
                while cursor <= finalLocation {
                    let line = source.lineRange(for: NSRange(location: cursor, length: 0))
                    if lineLocations.insert(line.location).inserted {
                        lines.append(line)
                    }
                    let next = NSMaxRange(line)
                    guard next > cursor else { break }
                    cursor = next
                }
            }
        } else {
            var cursor = 0
            while cursor < source.length {
                let line = source.lineRange(for: NSRange(location: cursor, length: 0))
                lines.append(line)
                cursor = NSMaxRange(line)
            }
        }
        return lines.compactMap { containerIndentedBlock(in: source, lineRange: $0) }
    }

    static func parts(in source: NSString, range: NSRange) -> Parts {
        guard range.length > 0 else {
            return Parts(content: range, openFence: nil, closeFence: nil)
        }
        let firstLine = NSIntersectionRange(
            source.lineRange(for: NSRange(location: range.location, length: 0)),
            range
        )
        guard let opening = fenceMarker(in: source, lineRange: firstLine) else {
            return Parts(content: trimmingTrailingLineEnding(range, in: source), openFence: nil, closeFence: nil)
        }
        let lastLine = NSIntersectionRange(
            source.lineRange(for: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: 0)),
            range
        )
        let closing = fenceMarker(in: source, lineRange: lastLine, matching: opening.character, minimum: opening.length)
        let contentStart = NSMaxRange(firstLine)
        let contentEnd = closing == nil ? NSMaxRange(range) : lastLine.location
        return Parts(
            content: NSRange(location: contentStart, length: max(0, contentEnd - contentStart)),
            openFence: firstLine,
            closeFence: closing.map { _ in lastLine }
        )
    }

    private static func fenceMarker(
        in source: NSString,
        lineRange: NSRange,
        matching expectedCharacter: unichar? = nil,
        minimum: Int = 3,
        afterContainer containerStart: Int? = nil
    ) -> (range: NSRange, character: unichar, length: Int)? {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let character = source.character(at: end - 1)
            guard character == 10 || character == 13 else { break }
            end -= 1
        }
        let markerStart: Int
        if var cursor = containerStart {
            var indentation = 0
            while cursor < end, indentation < 4, source.character(at: cursor) == 32 {
                cursor += 1
                indentation += 1
            }
            guard indentation <= 3 else { return nil }
            markerStart = cursor
        } else {
            guard let start = markdownStart(
                in: source,
                start: lineRange.location,
                end: end
            ) else { return nil }
            markerStart = start
        }
        guard markerStart < end else { return nil }
        var cursor = markerStart
        let character = source.character(at: cursor)
        guard character == expectedCharacter ?? character,
              character == 96 || character == 126 else { return nil }
        let start = cursor
        while cursor < end, source.character(at: cursor) == character { cursor += 1 }
        guard cursor - start >= minimum else { return nil }
        return (NSRange(location: start, length: cursor - start), character, cursor - start)
    }

    private static func openingFence(in source: NSString, lineRange: NSRange) -> Fence? {
        guard let marker = fenceMarker(in: source, lineRange: lineRange) else { return nil }
        let lineEnd = contentEnd(of: lineRange, in: source)
        if marker.character == 96,
           source.substring(with: NSRange(
               location: NSMaxRange(marker.range),
               length: lineEnd - NSMaxRange(marker.range)
           )).contains("`") { return nil }
        return Fence(
            character: marker.character,
            length: marker.length,
            containers: containers(in: source, lineRange: lineRange, before: marker.range.location)
        )
    }

    private static func isClosingFence(
        in source: NSString,
        lineRange: NSRange,
        opening: Fence
    ) -> Bool {
        guard let containerStart = continuationStart(
            in: source,
            lineRange: lineRange,
            containers: opening.containers
        ) else { return false }
        guard let marker = fenceMarker(
            in: source,
            lineRange: lineRange,
            matching: opening.character,
            minimum: opening.length,
            afterContainer: containerStart
        ) else { return false }
        let end = contentEnd(of: lineRange, in: source)
        var cursor = NSMaxRange(marker.range)
        while cursor < end,
              source.character(at: cursor) == 32 || source.character(at: cursor) == 9 {
            cursor += 1
        }
        return cursor == end
    }

    private static func containers(
        in source: NSString,
        lineRange: NSRange,
        before fenceStart: Int
    ) -> [Container] {
        var result: [Container] = []
        var cursor = lineRange.location
        var pendingIndent = 0
        while cursor < fenceStart {
            if source.character(at: cursor) == 32 {
                cursor += 1
                pendingIndent += 1
                continue
            }
            if source.character(at: cursor) == 62 {
                result.append(.quote)
                cursor += 1
                if cursor < fenceStart,
                   source.character(at: cursor) == 32 || source.character(at: cursor) == 9 {
                    cursor += 1
                }
                pendingIndent = 0
                continue
            }
            guard let markerEnd = listMarkerEnd(
                in: source,
                start: cursor,
                end: fenceStart
            ) else { break }
            let markerStart = cursor
            cursor = markerEnd
            while cursor < fenceStart,
                  source.character(at: cursor) == 32 || source.character(at: cursor) == 9 {
                cursor += 1
            }
            result.append(.list(indentation: pendingIndent + cursor - markerStart))
            pendingIndent = 0
        }
        return result
    }

    private static func continuesContainer(
        in source: NSString,
        lineRange: NSRange,
        containers: [Container]
    ) -> Bool {
        guard !containers.isEmpty else { return true }
        let end = contentEnd(of: lineRange, in: source)
        if source.substring(with: NSRange(
            location: lineRange.location,
            length: end - lineRange.location
        )).allSatisfy(\.isWhitespace) {
            return containers.allSatisfy {
                if case .list = $0 { true } else { false }
            }
        }
        return continuationStart(in: source, lineRange: lineRange, containers: containers) != nil
    }

    private static func continuationStart(
        in source: NSString,
        lineRange: NSRange,
        containers: [Container]
    ) -> Int? {
        let end = contentEnd(of: lineRange, in: source)
        var cursor = lineRange.location
        for container in containers {
            switch container {
            case .quote:
                var indentation = 0
                while cursor < end,
                      indentation < 3,
                      source.character(at: cursor) == 32 {
                    cursor += 1
                    indentation += 1
                }
                guard cursor < end, source.character(at: cursor) == 62 else { return nil }
                cursor += 1
                if cursor < end,
                   source.character(at: cursor) == 32 || source.character(at: cursor) == 9 {
                    cursor += 1
                }
            case .list(let indentation):
                var consumed = 0
                while cursor < end, consumed < indentation {
                    let character = source.character(at: cursor)
                    guard character == 32 || character == 9 else { return nil }
                    cursor += 1
                    consumed += character == 9 ? 4 - consumed % 4 : 1
                }
                guard consumed >= indentation else { return nil }
            }
        }
        return cursor
    }

    private static func markdownStart(in source: NSString, start: Int, end: Int) -> Int? {
        var cursor = start
        var leadingSpaces = 0
        while cursor < end, leadingSpaces < 4, source.character(at: cursor) == 32 {
            cursor += 1
            leadingSpaces += 1
        }
        guard leadingSpaces <= 3 else { return nil }

        while cursor < end {
            if source.character(at: cursor) == 62 {
                cursor += 1
                if cursor < end,
                   source.character(at: cursor) == 32 || source.character(at: cursor) == 9 {
                    cursor += 1
                }
                while cursor < end, source.character(at: cursor) == 32 { cursor += 1 }
                continue
            }
            guard let markerEnd = listMarkerEnd(
                in: source,
                start: cursor,
                end: end
            ) else { break }
            cursor = markerEnd
            while cursor < end,
                  source.character(at: cursor) == 32 || source.character(at: cursor) == 9 {
                cursor += 1
            }
        }
        return cursor
    }

    private static func listMarkerEnd(in source: NSString, start: Int, end: Int) -> Int? {
        guard start < end else { return nil }
        var cursor = start
        let first = source.character(at: cursor)
        if first == 45 || first == 42 || first == 43 {
            cursor += 1
        } else if first >= 48, first <= 57 {
            var digits = 0
            while cursor < end,
                  source.character(at: cursor) >= 48,
                  source.character(at: cursor) <= 57,
                  digits < 9 {
                cursor += 1
                digits += 1
            }
            guard cursor < end,
                  source.character(at: cursor) == 46 || source.character(at: cursor) == 41 else { return nil }
            cursor += 1
        } else {
            return nil
        }
        guard cursor < end,
              source.character(at: cursor) == 32 || source.character(at: cursor) == 9 else { return nil }
        return cursor
    }

    private static func containerIndentedBlock(
        in source: NSString,
        lineRange: NSRange
    ) -> IndentedBlock? {
        let end = contentEnd(of: lineRange, in: source)
        var cursor = lineRange.location
        var leading = 0
        while cursor < end, leading < 4, source.character(at: cursor) == 32 {
            cursor += 1
            leading += 1
        }
        guard leading <= 3 else { return nil }

        while cursor < end {
            if source.character(at: cursor) == 62 {
                cursor += 1
            } else if let markerEnd = listMarkerEnd(in: source, start: cursor, end: end) {
                cursor = markerEnd
            } else {
                return nil
            }
            if cursor < end,
               source.character(at: cursor) == 32 || source.character(at: cursor) == 9 {
                cursor += 1
            }
            var indentationColumns = 0
            while cursor < end, indentationColumns < 4 {
                let character = source.character(at: cursor)
                if character == 32 {
                    indentationColumns += 1
                    cursor += 1
                } else if character == 9 {
                    indentationColumns += 4 - (indentationColumns % 4)
                    cursor += 1
                } else {
                    break
                }
            }
            if indentationColumns >= 4 {
                guard cursor < end else { return nil }
                return IndentedBlock(
                    range: lineRange,
                    content: NSRange(location: cursor, length: end - cursor)
                )
            }
        }
        return nil
    }

    private static func contentEnd(of lineRange: NSRange, in source: NSString) -> Int {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location,
              source.character(at: end - 1) == 10 || source.character(at: end - 1) == 13 {
            end -= 1
        }
        return end
    }

    private static func trimmingTrailingLineEnding(_ range: NSRange, in source: NSString) -> NSRange {
        var end = NSMaxRange(range)
        while end > range.location {
            let character = source.character(at: end - 1)
            guard character == 10 || character == 13 else { break }
            end -= 1
        }
        return NSRange(location: range.location, length: end - range.location)
    }
}

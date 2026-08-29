//
//  MarkdownTextProjection.swift
//  MarkdownEngine
//

import Foundation

/// One contiguous relationship between source and visible UTF-16 ranges.
///
/// Most spans copy source text byte for byte and therefore have equal lengths.
/// A rendered table uses a tab for a source pipe and a newline for `<br>`, so
/// those spans map one source token to a shorter visible replacement.
public struct MarkdownTextProjectionSpan: Sendable, Equatable {
    public let sourceRange: NSRange
    public let visibleRange: NSRange

    public init(sourceRange: NSRange, visibleRange: NSRange) {
        self.sourceRange = sourceRange
        self.visibleRange = visibleRange
    }
}

/// The text exposed by the current editor presentation and its source mapping.
///
/// Rich and preview projections omit Markdown syntax that the editor hides.
/// Raw source mode is an identity projection. Ranges use UTF-16, matching
/// `NSTextView`, `NSRange` and ``MarkdownTextMutation``.
public struct MarkdownTextProjection: Sendable, Equatable {
    public let string: String
    public let sourceUTF16Length: Int
    public let spans: [MarkdownTextProjectionSpan]

    public var visibleUTF16Length: Int { (string as NSString).length }

    /// Build the projection for one editor configuration.
    public static func make(
        markdown: String,
        configuration: MarkdownEditorConfiguration = .default
    ) -> MarkdownTextProjection {
        if configuration.rawSourceMode {
            return identity(markdown)
        }
        return MarkdownTextProjectionBuilder.rich(
            markdown,
            registry: configuration.extensionRegistry
        )
    }

    /// The source range covering a visible range. A result crossing hidden
    /// syntax includes that syntax so a replace remains one contiguous edit.
    public func sourceRange(for visibleRange: NSRange) -> NSRange? {
        guard Self.isValid(visibleRange, length: visibleUTF16Length) else { return nil }
        guard visibleRange.length > 0 else {
            return NSRange(location: sourceLocation(forVisibleBoundary: visibleRange.location), length: 0)
        }
        let visibleEnd = NSMaxRange(visibleRange)
        guard let first = span(containingVisibleOffset: visibleRange.location),
              let last = span(containingVisibleOffset: visibleEnd - 1) else { return nil }

        let start = Self.sourceOffset(
            forVisibleOffset: visibleRange.location,
            in: first,
            endBoundary: false
        )
        let end = Self.sourceOffset(
            forVisibleOffset: visibleEnd,
            in: last,
            endBoundary: true
        )
        return NSRange(location: start, length: end - start)
    }

    /// The visible range covered by a source range. A fully hidden source run
    /// maps to a zero-length range at the next visible character.
    public func visibleRange(for sourceRange: NSRange) -> NSRange? {
        guard Self.isValid(sourceRange, length: sourceUTF16Length) else { return nil }
        guard sourceRange.length > 0 else {
            return NSRange(location: visibleLocation(forSourceBoundary: sourceRange.location), length: 0)
        }
        let sourceEnd = NSMaxRange(sourceRange)
        let firstIndex = firstSpanEnding(afterSourceOffset: sourceRange.location)
        let lastIndex = lastSpanStarting(beforeSourceOffset: sourceEnd)
        guard firstIndex < spans.count,
              lastIndex >= firstIndex,
              spans[firstIndex].sourceRange.location < sourceEnd,
              NSMaxRange(spans[lastIndex].sourceRange) > sourceRange.location
        else {
            return NSRange(location: visibleLocation(forSourceBoundary: sourceRange.location), length: 0)
        }
        let first = spans[firstIndex]
        let last = spans[lastIndex]

        let start = Self.visibleOffset(
            forSourceOffset: max(sourceRange.location, first.sourceRange.location),
            in: first,
            endBoundary: false
        )
        let end = Self.visibleOffset(
            forSourceOffset: min(sourceEnd, NSMaxRange(last.sourceRange)),
            in: last,
            endBoundary: true
        )
        return NSRange(location: start, length: end - start)
    }

    static func identity(_ source: String) -> MarkdownTextProjection {
        let length = (source as NSString).length
        let range = NSRange(location: 0, length: length)
        return MarkdownTextProjection(
            string: source,
            sourceUTF16Length: length,
            spans: length == 0 ? [] : [MarkdownTextProjectionSpan(
                sourceRange: range,
                visibleRange: range
            )]
        )
    }

    private static func isValid(_ range: NSRange, length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }

    private func sourceLocation(forVisibleBoundary offset: Int) -> Int {
        let index = firstSpanEnding(afterVisibleOffset: offset)
        guard index < spans.count else { return sourceUTF16Length }
        let span = spans[index]
        return Self.sourceOffset(
            forVisibleOffset: max(offset, span.visibleRange.location),
            in: span,
            endBoundary: false
        )
    }

    private func visibleLocation(forSourceBoundary offset: Int) -> Int {
        let index = firstSpanEnding(afterSourceOffset: offset)
        guard index < spans.count else { return visibleUTF16Length }
        let span = spans[index]
        return Self.visibleOffset(
            forSourceOffset: max(offset, span.sourceRange.location),
            in: span,
            endBoundary: false
        )
    }

    private func span(containingVisibleOffset offset: Int) -> MarkdownTextProjectionSpan? {
        let index = firstSpanEnding(afterVisibleOffset: offset)
        guard index < spans.count,
              spans[index].visibleRange.location <= offset else { return nil }
        return spans[index]
    }

    private func firstSpanEnding(afterVisibleOffset offset: Int) -> Int {
        lowerBound { NSMaxRange($0.visibleRange) > offset }
    }

    private func firstSpanEnding(afterSourceOffset offset: Int) -> Int {
        lowerBound { NSMaxRange($0.sourceRange) > offset }
    }

    private func lastSpanStarting(beforeSourceOffset offset: Int) -> Int {
        lowerBound { $0.sourceRange.location >= offset } - 1
    }

    private func lowerBound(
        where predicate: (MarkdownTextProjectionSpan) -> Bool
    ) -> Int {
        var lower = 0
        var upper = spans.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(spans[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }

    private static func sourceOffset(
        forVisibleOffset offset: Int,
        in span: MarkdownTextProjectionSpan,
        endBoundary: Bool
    ) -> Int {
        let delta = offset - span.visibleRange.location
        if span.sourceRange.length == span.visibleRange.length {
            return span.sourceRange.location + delta
        }
        if delta == 0 { return span.sourceRange.location }
        return endBoundary ? NSMaxRange(span.sourceRange) : span.sourceRange.location
    }

    private static func visibleOffset(
        forSourceOffset offset: Int,
        in span: MarkdownTextProjectionSpan,
        endBoundary: Bool
    ) -> Int {
        let delta = offset - span.sourceRange.location
        if span.sourceRange.length == span.visibleRange.length {
            return span.visibleRange.location + delta
        }
        if delta == 0 { return span.visibleRange.location }
        return endBoundary ? NSMaxRange(span.visibleRange) : span.visibleRange.location
    }
}

private enum MarkdownTextProjectionBuilder {
    private static let tableBreakExpression = try? NSRegularExpression(
        pattern: #"<br\s*/?>"#,
        options: [.caseInsensitive]
    )

    private struct Replacement {
        let sourceRange: NSRange
        let text: String
    }

    private enum Operation {
        case remove(NSRange)
        case replace(Replacement)

        var range: NSRange {
            switch self {
            case .remove(let range): range
            case .replace(let replacement): replacement.sourceRange
            }
        }
    }

    static func rich(_ source: String, registry: ExtensionRegistry) -> MarkdownTextProjection {
        let ns = source as NSString
        let blocks = DocumentAST.parse(source, registry: registry)
        let definitions = referenceDefinitions(in: blocks, source: ns)
        var removals: [NSRange] = []
        var replacements: [Replacement] = []

        for block in blocks {
            collect(
                block,
                source: ns,
                registry: registry,
                referenceDefinitions: definitions,
                removals: &removals,
                replacements: &replacements
            )
        }

        return build(
            source,
            removals: removals,
            replacements: replacements
        )
    }

    private static func referenceDefinitions(
        in blocks: [BlockNode],
        source: NSString
    ) -> Set<String> {
        Set(blocks.compactMap { block in
            guard case .linkDefinition(_, let label, _, _) = block else { return nil }
            return MarkdownLinkSyntax.normalizedLabel(in: source, range: label)
        })
    }

    private static func collect(
        _ block: BlockNode,
        source: NSString,
        registry: ExtensionRegistry,
        referenceDefinitions: Set<String>,
        removals: inout [NSRange],
        replacements: inout [Replacement]
    ) {
        switch block {
        case .frontmatter(let range), .linkDefinition(let range, _, _, _):
            removals.append(range)

        case .footnoteDefinition(_, _, let markers, let inlines):
            removals += markers
            collect(
                inlines,
                source: source,
                referenceDefinitions: referenceDefinitions,
                removals: &removals
            )

        case .paragraph(_, let inlines):
            collect(
                inlines,
                source: source,
                referenceDefinitions: referenceDefinitions,
                removals: &removals
            )

        case .heading(_, _, let markers, let inlines):
            removals += markers
            collect(
                inlines,
                source: source,
                referenceDefinitions: referenceDefinitions,
                removals: &removals
            )

        case .blockquote(let range, let inlines):
            removals += blockquoteMarkers(in: range, source: source)
            collect(
                inlines,
                source: source,
                referenceDefinitions: referenceDefinitions,
                removals: &removals
            )

        case .list(_, let items):
            for item in items {
                removals.append(NSRange(
                    location: item.marker.location,
                    length: item.contentRange.location - item.marker.location
                ))
                collect(
                    item.inlines,
                    source: source,
                    referenceDefinitions: referenceDefinitions,
                    removals: &removals
                )
            }

        case .codeBlock(let range):
            removals += codeFenceLines(in: range, source: source)

        case .table(let range):
            collectTable(
                in: range,
                source: source,
                registry: registry,
                referenceDefinitions: referenceDefinitions,
                removals: &removals,
                replacements: &replacements
            )

        case .thematicBreak(let range):
            removals += nonLineBreakRanges(in: range, source: source)

        case .ext(let node):
            removals.append(node.openFence)
            if let closeFence = node.closeFence { removals.append(closeFence) }
            collect(
                node.inlines,
                source: source,
                referenceDefinitions: referenceDefinitions,
                removals: &removals
            )

        case .blank:
            break
        }
    }

    private static func collect(
        _ nodes: [InlineNode],
        source: NSString,
        referenceDefinitions: Set<String>,
        removals: inout [NSRange]
    ) {
        for node in nodes {
            switch node {
            case .text:
                break

            case .code(let range, let content):
                removals += outside(content, in: range)

            case .emphasis(_, _, let markers, let children):
                removals += markers
                collect(
                    children,
                    source: source,
                    referenceDefinitions: referenceDefinitions,
                    removals: &removals
                )

            case .link(let range, let textRange, _, _, _, let children):
                removals += outside(textRange, in: range)
                collect(
                    children,
                    source: source,
                    referenceDefinitions: referenceDefinitions,
                    removals: &removals
                )

            case .image(let range, let alt, _, _, _):
                removals += outside(alt, in: range)
                removals += MarkdownLinkSyntax.escapeMarkerRanges(in: source, range: alt)

            case .referenceLink(let range, let textRange, let label, _, let children):
                let definitionLabel = label ?? textRange
                let key = MarkdownLinkSyntax.normalizedLabel(in: source, range: definitionLabel)
                if referenceDefinitions.contains(key) {
                    removals += outside(textRange, in: range)
                }
                if let label {
                    removals += MarkdownLinkSyntax.escapeMarkerRanges(in: source, range: label)
                }
                collect(
                    children,
                    source: source,
                    referenceDefinitions: referenceDefinitions,
                    removals: &removals
                )

            case .footnoteReference(let range, let label, _):
                removals += outside(label, in: range)

            case .hardBreak(_, let marker):
                removals.append(marker)

            case .autolink(let range, let url, _):
                removals += outside(url, in: range)

            case .escape(_, _, let marker):
                removals.append(marker)

            case .ext(let node):
                removals += node.markers
                collect(
                    node.children,
                    source: source,
                    referenceDefinitions: referenceDefinitions,
                    removals: &removals
                )
            }
        }
    }

    private static func outside(_ content: NSRange, in range: NSRange) -> [NSRange] {
        let prefix = NSRange(
            location: range.location,
            length: content.location - range.location
        )
        let suffix = NSRange(
            location: NSMaxRange(content),
            length: NSMaxRange(range) - NSMaxRange(content)
        )
        return [prefix, suffix].filter { $0.length > 0 }
    }

    private static func blockquoteMarkers(in range: NSRange, source: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            let line = NSIntersectionRange(
                source.lineRange(for: NSRange(location: cursor, length: 0)),
                range
            )
            let contentEnd = lineContentEnd(line, source: source)
            var markerStart = line.location
            var indent = 0
            while markerStart < contentEnd, indent < 3,
                  isHorizontalWhitespace(source.character(at: markerStart)) {
                markerStart += 1
                indent += 1
            }
            var markerEnd = markerStart
            while markerEnd < contentEnd, source.character(at: markerEnd) == 0x3E {
                markerEnd += 1
                if markerEnd < contentEnd,
                   isHorizontalWhitespace(source.character(at: markerEnd)) {
                    markerEnd += 1
                }
            }
            if markerEnd > markerStart {
                result.append(NSRange(location: markerStart, length: markerEnd - markerStart))
            }
            let next = NSMaxRange(line)
            guard next > cursor else { break }
            cursor = next
        }
        return result
    }

    private static func codeFenceLines(in range: NSRange, source: NSString) -> [NSRange] {
        guard range.length > 0 else { return [] }
        let firstLine = NSIntersectionRange(
            source.lineRange(for: NSRange(location: range.location, length: 0)),
            range
        )
        let firstEnd = lineContentEnd(firstLine, source: source)
        var runEnd = firstLine.location
        let fence = source.character(at: runEnd)
        while runEnd < firstEnd, source.character(at: runEnd) == fence { runEnd += 1 }
        guard fence == 0x60 || fence == 0x7E, runEnd - firstLine.location >= 3 else {
            return []
        }

        var result = [firstLine]
        let lastLocation = max(range.location, NSMaxRange(range) - 1)
        let lastLine = NSIntersectionRange(
            source.lineRange(for: NSRange(location: lastLocation, length: 0)),
            range
        )
        guard lastLine.location > firstLine.location else { return result }
        let lastEnd = lineContentEnd(lastLine, source: source)
        var closeEnd = lastLine.location
        while closeEnd < lastEnd, source.character(at: closeEnd) == fence { closeEnd += 1 }
        var suffix = closeEnd
        while suffix < lastEnd, isHorizontalWhitespace(source.character(at: suffix)) {
            suffix += 1
        }
        if closeEnd - lastLine.location >= runEnd - firstLine.location, suffix == lastEnd {
            result.append(lastLine)
        }
        return result
    }

    private static func nonLineBreakRanges(in range: NSRange, source: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var runStart: Int?
        for offset in range.location..<NSMaxRange(range) {
            let character = source.character(at: offset)
            let isLineBreak = character == 0x0A || character == 0x0D
            if isLineBreak, let start = runStart {
                result.append(NSRange(location: start, length: offset - start))
                runStart = nil
            } else if !isLineBreak, runStart == nil {
                runStart = offset
            }
        }
        if let start = runStart {
            result.append(NSRange(location: start, length: NSMaxRange(range) - start))
        }
        return result
    }

    private static func collectTable(
        in range: NSRange,
        source: NSString,
        registry: ExtensionRegistry,
        referenceDefinitions: Set<String>,
        removals: inout [NSRange],
        replacements: inout [Replacement]
    ) {
        var lines: [NSRange] = []
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            let line = NSIntersectionRange(
                source.lineRange(for: NSRange(location: cursor, length: 0)),
                range
            )
            lines.append(line)
            let next = NSMaxRange(line)
            guard next > cursor else { break }
            cursor = next
        }
        guard lines.count >= 2 else { return }
        removals.append(lines[1])

        for (index, line) in lines.enumerated() where index != 1 {
            let contentEnd = lineContentEnd(line, source: source)
            let delimiters = tableDelimiters(
                from: line.location,
                to: contentEnd,
                source: source
            )
            guard delimiters.count >= 2 else { continue }

            removals.append(NSRange(
                location: line.location,
                length: delimiters[0] - line.location + 1
            ))
            for delimiter in delimiters.dropFirst().dropLast() {
                replacements.append(Replacement(
                    sourceRange: NSRange(location: delimiter, length: 1),
                    text: "\t"
                ))
            }
            removals.append(NSRange(
                location: delimiters.last!,
                length: contentEnd - delimiters.last!
            ))

            for pair in zip(delimiters, delimiters.dropFirst()) {
                var start = pair.0 + 1
                var end = pair.1
                while start < end, isHorizontalWhitespace(source.character(at: start)) {
                    start += 1
                }
                while end > start, isHorizontalWhitespace(source.character(at: end - 1)) {
                    end -= 1
                }
                if start > pair.0 + 1 {
                    removals.append(NSRange(location: pair.0 + 1, length: start - pair.0 - 1))
                }
                if end < pair.1 {
                    removals.append(NSRange(location: end, length: pair.1 - end))
                }
                guard end > start else { continue }
                let cell = NSRange(location: start, length: end - start)
                collect(
                    InlineParser.parse(source, range: cell, registry: registry),
                    source: source,
                    referenceDefinitions: referenceDefinitions,
                    removals: &removals
                )
                collectTableBreaks(
                    in: cell,
                    source: source,
                    replacements: &replacements
                )
            }
        }
    }

    private static func tableDelimiters(
        from start: Int,
        to end: Int,
        source: NSString
    ) -> [Int] {
        var result: [Int] = []
        var escaped = false
        for offset in start..<end {
            let character = source.character(at: offset)
            if escaped {
                escaped = false
            } else if character == 0x5C {
                escaped = true
            } else if character == 0x7C {
                result.append(offset)
            }
        }
        return result
    }

    private static func collectTableBreaks(
        in range: NSRange,
        source: NSString,
        replacements: inout [Replacement]
    ) {
        guard let expression = tableBreakExpression else { return }
        let text = source as String
        for match in expression.matches(in: text, range: range) {
            replacements.append(Replacement(sourceRange: match.range, text: "\n"))
        }
    }

    private static func build(
        _ source: String,
        removals: [NSRange],
        replacements: [Replacement]
    ) -> MarkdownTextProjection {
        let ns = source as NSString
        let sourceLength = ns.length
        let replacements = replacements
            .compactMap { replacement -> Replacement? in
                guard isValid(replacement.sourceRange, length: sourceLength) else { return nil }
                return Replacement(
                    sourceRange: ns.rangeOfComposedCharacterSequences(for: replacement.sourceRange),
                    text: replacement.text
                )
            }
            .sorted { $0.sourceRange.location < $1.sourceRange.location }

        let expandedRemovals = removals.compactMap { range -> NSRange? in
            guard range.length > 0, isValid(range, length: sourceLength) else { return nil }
            return ns.rangeOfComposedCharacterSequences(for: range)
        }
        let normalizedRemovals = merge(expandedRemovals)

        var operations: [Operation] = normalizedRemovals.map(Operation.remove)
        operations += replacements.map(Operation.replace)
        operations.sort { $0.range.location < $1.range.location }

        var visible = ""
        var visibleLength = 0
        var spans: [MarkdownTextProjectionSpan] = []
        var cursor = 0

        func append(_ text: String, sourceRange: NSRange) {
            let length = (text as NSString).length
            guard length > 0 else { return }
            visible += text
            spans.append(MarkdownTextProjectionSpan(
                sourceRange: sourceRange,
                visibleRange: NSRange(location: visibleLength, length: length)
            ))
            visibleLength += length
        }

        for operation in operations {
            let range = operation.range
            guard range.location >= cursor else { continue }
            if range.location > cursor {
                let retained = NSRange(location: cursor, length: range.location - cursor)
                append(ns.substring(with: retained), sourceRange: retained)
            }
            if case .replace(let replacement) = operation {
                append(replacement.text, sourceRange: replacement.sourceRange)
            }
            cursor = NSMaxRange(range)
        }
        if cursor < sourceLength {
            let retained = NSRange(location: cursor, length: sourceLength - cursor)
            append(ns.substring(with: retained), sourceRange: retained)
        }

        return MarkdownTextProjection(
            string: visible,
            sourceUTF16Length: sourceLength,
            spans: spans
        )
    }

    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        var result: [NSRange] = []
        for range in sorted {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            guard range.location <= NSMaxRange(last) else {
                result.append(range)
                continue
            }
            let end = max(NSMaxRange(last), NSMaxRange(range))
            result[result.count - 1].length = end - last.location
        }
        return result
    }

    private static func lineContentEnd(_ range: NSRange, source: NSString) -> Int {
        var end = NSMaxRange(range)
        while end > range.location {
            let character = source.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        return end
    }

    private static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    private static func isValid(_ range: NSRange, length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }
}

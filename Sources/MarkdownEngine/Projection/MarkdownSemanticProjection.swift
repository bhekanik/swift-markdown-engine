import Foundation

/// The parser-owned Markdown constructs that affect writing commands.
public enum MarkdownSemanticKind: Sendable, Equatable {
    case emphasis(MarkdownEmphasisKind)
    case inlineCode
    case codeBlock
    case inlineExtension(identifier: String)
    case blockExtension(identifier: String)
}

public enum MarkdownEmphasisKind: Sendable, Equatable {
    case italic
    case bold
    case boldItalic
}

/// One parsed construct in absolute UTF-16 source coordinates.
public struct MarkdownSemanticSpan: Sendable, Equatable {
    public let kind: MarkdownSemanticKind
    public let range: NSRange
    public let contentRange: NSRange
    public let markerRanges: [NSRange]

    public init(
        kind: MarkdownSemanticKind,
        range: NSRange,
        contentRange: NSRange,
        markerRanges: [NSRange]
    ) {
        self.kind = kind
        self.range = range
        self.contentRange = contentRange
        self.markerRanges = markerRanges
    }
}

/// Semantic ranges from the same AST used by rendering and text projection.
public struct MarkdownSemanticProjection: Sendable, Equatable {
    public let spans: [MarkdownSemanticSpan]

    public static func make(
        markdown: String,
        configuration: MarkdownEditorConfiguration = .default
    ) -> MarkdownSemanticProjection {
        make(markdown: markdown, scopedRanges: nil, configuration: configuration)
    }

    public static func make(
        markdown: String,
        intersecting range: NSRange,
        configuration: MarkdownEditorConfiguration = .default
    ) -> MarkdownSemanticProjection {
        let length = (markdown as NSString).length
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= length else {
            return MarkdownSemanticProjection(spans: [])
        }
        let scope = if range.length > 0 {
            range
        } else if range.location < length {
            NSRange(location: range.location, length: 1)
        } else if length > 0 {
            NSRange(location: length - 1, length: 1)
        } else {
            NSRange(location: 0, length: 0)
        }
        return make(
            markdown: markdown,
            scopedRanges: scope.length > 0 ? [scope] : [],
            configuration: configuration
        )
    }

    private static func make(
        markdown: String,
        scopedRanges: [NSRange]?,
        configuration: MarkdownEditorConfiguration
    ) -> MarkdownSemanticProjection {
        let source = markdown as NSString
        var spans: [MarkdownSemanticSpan] = []
        if let line = localLineScope(in: source, scopedRanges: scopedRanges) {
            let localSource = source.substring(with: line) as NSString
            var localSpans: [MarkdownSemanticSpan] = []
            for block in DocumentAST.parse(
                localSource as String,
                registry: configuration.extensionRegistry
            ) {
                collect(
                    block,
                    source: localSource,
                    registry: configuration.extensionRegistry,
                    into: &localSpans
                )
            }
            spans.append(contentsOf: localSpans.map { shifted($0, by: line.location) })
        } else {
            for block in DocumentAST.parse(
                markdown,
                scopedRanges: scopedRanges,
                registry: configuration.extensionRegistry
            ) {
                collect(
                    block,
                    source: source,
                    registry: configuration.extensionRegistry,
                    into: &spans
                )
            }
        }
        let fencedBlocks = containsFenceCandidate(in: source)
            ? MarkdownCodeBlockSyntax.fencedBlocks(in: source)
            : []
        for block in fencedBlocks where scopedRanges?.contains(where: {
                intersects($0, block.range)
                    || ($0.location == source.length
                        && block.closeFence == nil
                        && NSMaxRange(block.range) == source.length)
            }) ?? true {
            spans.removeAll { span in
                span.range.location >= block.range.location
                    && NSMaxRange(span.range) <= NSMaxRange(block.range)
            }
            spans.append(MarkdownSemanticSpan(
                kind: .codeBlock,
                range: block.range,
                contentRange: block.content,
                markerRanges: [block.openFence, block.closeFence].compactMap { $0 }
            ))
        }
        for block in MarkdownCodeBlockSyntax.containerIndentedBlocks(
            in: source,
            intersecting: scopedRanges
        ) {
            spans.removeAll { span in
                span.range.location >= block.range.location
                    && NSMaxRange(span.range) <= NSMaxRange(block.range)
            }
            spans.append(MarkdownSemanticSpan(
                kind: .codeBlock,
                range: block.range,
                contentRange: block.content,
                markerRanges: []
            ))
        }
        if let scopedRanges {
            spans.removeAll { span in
                !scopedRanges.contains { intersects($0, span.range) }
            }
        }
        spans.sort {
            $0.range.location == $1.range.location
                ? $0.range.length > $1.range.length
                : $0.range.location < $1.range.location
        }
        return MarkdownSemanticProjection(spans: spans)
    }

    private static func localLineScope(
        in source: NSString,
        scopedRanges: [NSRange]?
    ) -> NSRange? {
        guard let scopedRanges, scopedRanges.count == 1,
              let scope = scopedRanges.first,
              source.length > 0 else { return nil }
        let first = source.lineRange(for: NSRange(
            location: min(scope.location, source.length - 1),
            length: 0
        ))
        let last = source.lineRange(for: NSRange(
            location: min(max(scope.location, NSMaxRange(scope) - 1), source.length - 1),
            length: 0
        ))
        guard first == last,
              !hasSemanticDelimiterOutsideLine(first, in: source) else { return nil }
        return first
    }

    private static func hasSemanticDelimiterOutsideLine(
        _ line: NSRange,
        in source: NSString
    ) -> Bool {
        containsSemanticDelimiterBefore(line.location, in: source)
            || containsSemanticDelimiterAfter(NSMaxRange(line), in: source)
    }

    private static func containsSemanticDelimiterBefore(
        _ end: Int,
        in source: NSString
    ) -> Bool {
        var cursor = end
        consumeLineEndingBackward(in: source, cursor: &cursor)
        var lineHasContent = false
        while cursor > 0 {
            cursor -= 1
            let character = source.character(at: cursor)
            if isLineEnding(character) {
                if character == 10, cursor > 0, source.character(at: cursor - 1) == 13 {
                    cursor -= 1
                }
                if !lineHasContent { return false }
                lineHasContent = false
            } else if character != 9, character != 32 {
                lineHasContent = true
                if isSemanticDelimiter(character) { return true }
            }
        }
        return false
    }

    private static func containsSemanticDelimiterAfter(
        _ start: Int,
        in source: NSString
    ) -> Bool {
        var cursor = start
        var lineHasContent = false
        while cursor < source.length {
            let character = source.character(at: cursor)
            cursor += 1
            if isLineEnding(character) {
                if character == 13,
                   cursor < source.length,
                   source.character(at: cursor) == 10 {
                    cursor += 1
                }
                if !lineHasContent { return false }
                lineHasContent = false
            } else if character != 9, character != 32 {
                lineHasContent = true
                if isSemanticDelimiter(character) { return true }
            }
        }
        return false
    }

    private static func consumeLineEndingBackward(
        in source: NSString,
        cursor: inout Int
    ) {
        guard cursor > 0 else { return }
        if source.character(at: cursor - 1) == 10 {
            cursor -= 1
            if cursor > 0, source.character(at: cursor - 1) == 13 {
                cursor -= 1
            }
        } else if source.character(at: cursor - 1) == 13 {
            cursor -= 1
        }
    }

    private static func isLineEnding(_ character: unichar) -> Bool {
        character == 10 || character == 13
    }

    private static func isSemanticDelimiter(_ character: unichar) -> Bool {
        character == 42 || character == 95 || character == 96 || character == 126
    }

    private static func containsFenceCandidate(in source: NSString) -> Bool {
        source.range(of: "```").location != NSNotFound
            || source.range(of: "~~~").location != NSNotFound
    }

    private static func shifted(
        _ span: MarkdownSemanticSpan,
        by offset: Int
    ) -> MarkdownSemanticSpan {
        MarkdownSemanticSpan(
            kind: span.kind,
            range: shifted(span.range, by: offset),
            contentRange: shifted(span.contentRange, by: offset),
            markerRanges: span.markerRanges.map { shifted($0, by: offset) }
        )
    }

    private static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    private static func intersects(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        lhs.location < NSMaxRange(rhs) && NSMaxRange(lhs) > rhs.location
    }

    private static func collect(
        _ block: BlockNode,
        source: NSString,
        registry: ExtensionRegistry,
        into spans: inout [MarkdownSemanticSpan]
    ) {
        switch block {
        case .footnoteDefinition(_, _, _, let inlines),
             .paragraph(_, let inlines),
             .heading(_, _, _, let inlines),
             .blockquote(_, let inlines):
            collect(inlines, map: { $0 }, into: &spans)
        case .list(_, let items):
            for item in items { collect(item.inlines, map: { $0 }, into: &spans) }
        case .codeBlock(let range):
            let parts = MarkdownCodeBlockSyntax.parts(in: source, range: range)
            spans.append(MarkdownSemanticSpan(
                kind: .codeBlock,
                range: range,
                contentRange: parts.content,
                markerRanges: [parts.openFence, parts.closeFence].compactMap { $0 }
            ))
        case .ext(let node):
            spans.append(MarkdownSemanticSpan(
                kind: .blockExtension(identifier: node.extensionID),
                range: node.range,
                contentRange: node.contentRange,
                markerRanges: [node.openFence, node.closeFence].compactMap { $0 }
            ))
            collect(node.inlines, map: { $0 }, into: &spans)
        case .table(let range):
            let rows = MarkdownTableRowSource.rows(in: source, range: range)
            guard let columnCount = MarkdownTableRowSource.renderedColumnCount(in: rows) else {
                break
            }
            for (index, row) in rows.enumerated() where index != 1 {
                for cell in row.cells.prefix(columnCount) where !cell.normalizedText.isEmpty {
                    collect(
                        cell.inlineNodes(registry: registry, referenceDefinitions: []),
                        map: cell.sourceRange(forNormalizedRange:),
                        into: &spans
                    )
                }
            }
        case .frontmatter, .linkDefinition, .thematicBreak, .blank:
            break
        }
    }

    private static func collect(
        _ nodes: [InlineNode],
        map: (NSRange) -> NSRange?,
        into spans: inout [MarkdownSemanticSpan]
    ) {
        for node in nodes {
            switch node {
            case .emphasis(let kind, let range, let markers, let children):
                guard let range = map(range),
                      let content = map(contentRange(between: markers)) else { continue }
                spans.append(MarkdownSemanticSpan(
                    kind: .emphasis(publicKind(kind)),
                    range: range,
                    contentRange: content,
                    markerRanges: markers.compactMap(map)
                ))
                collect(children, map: map, into: &spans)
            case .code(let range, let content):
                guard let range = map(range), let content = map(content) else { continue }
                spans.append(MarkdownSemanticSpan(
                    kind: .inlineCode,
                    range: range,
                    contentRange: content,
                    markerRanges: outside(content, in: range)
                ))
            case .ext(let node):
                guard let range = map(node.range),
                      let content = map(node.contentRange) else { continue }
                spans.append(MarkdownSemanticSpan(
                    kind: .inlineExtension(identifier: node.extensionID),
                    range: range,
                    contentRange: content,
                    markerRanges: node.markers.compactMap(map)
                ))
                collect(node.children, map: map, into: &spans)
            case .link(_, _, _, _, _, let children),
                 .referenceImage(_, _, _, _, let children),
                 .referenceLink(_, _, _, _, let children):
                collect(children, map: map, into: &spans)
            case .text, .image, .footnoteReference, .hardBreak, .autolink, .escape:
                break
            }
        }
    }

    private static func publicKind(_ kind: EmphasisKind) -> MarkdownEmphasisKind {
        switch kind {
        case .italic: .italic
        case .bold: .bold
        case .boldItalic: .boldItalic
        }
    }

    private static func contentRange(between markers: [NSRange]) -> NSRange {
        guard let opening = markers.first, let closing = markers.last else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(
            location: NSMaxRange(opening),
            length: closing.location - NSMaxRange(opening)
        )
    }

    private static func outside(_ content: NSRange, in range: NSRange) -> [NSRange] {
        [
            NSRange(location: range.location, length: content.location - range.location),
            NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content)),
        ].filter { $0.length > 0 }
    }
}

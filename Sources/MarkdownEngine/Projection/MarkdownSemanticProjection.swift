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
        let source = markdown as NSString
        var spans: [MarkdownSemanticSpan] = []
        for block in DocumentAST.parse(
            markdown,
            registry: configuration.extensionRegistry
        ) {
            collect(
                block,
                source: source,
                registry: configuration.extensionRegistry,
                into: &spans
            )
        }
        for block in MarkdownCodeBlockSyntax.fencedBlocks(in: source) {
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
        spans.sort {
            $0.range.location == $1.range.location
                ? $0.range.length > $1.range.length
                : $0.range.location < $1.range.location
        }
        return MarkdownSemanticProjection(spans: spans)
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

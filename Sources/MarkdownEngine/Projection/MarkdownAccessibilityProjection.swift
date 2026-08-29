//
//  MarkdownAccessibilityProjection.swift
//  MarkdownEngine
//

import Foundation

/// Markdown structure exposed to assistive clients in visible coordinates.
public enum MarkdownAccessibilityRole: Sendable, Equatable {
    case heading(level: Int)
    case listItem(level: Int, index: Int, prefix: String, isChecked: Bool?)
    case link(destination: String)
    case image(label: String, destination: String)
    case footnoteReference(label: String)
    case footnoteDefinition(label: String)
}

/// One semantic source span and its reader-visible range.
public struct MarkdownAccessibilitySpan: Sendable, Equatable {
    public let sourceRange: NSRange
    public let visibleRange: NSRange
    public let role: MarkdownAccessibilityRole

    public init(
        sourceRange: NSRange,
        visibleRange: NSRange,
        role: MarkdownAccessibilityRole
    ) {
        self.sourceRange = sourceRange
        self.visibleRange = visibleRange
        self.role = role
    }
}

/// Visible Markdown text plus the structure VoiceOver can navigate.
public struct MarkdownAccessibilityProjection: Sendable, Equatable {
    public let text: MarkdownTextProjection
    public let spans: [MarkdownAccessibilitySpan]

    public static func make(
        markdown: String,
        configuration: MarkdownEditorConfiguration = .default
    ) -> MarkdownAccessibilityProjection {
        let text = MarkdownTextProjection.make(
            markdown: markdown,
            configuration: configuration
        )
        guard !configuration.rawSourceMode else {
            return MarkdownAccessibilityProjection(text: text, spans: [])
        }

        let registry = configuration.extensionRegistry
        let blocks = DocumentAST.parse(markdown, registry: registry)
        let candidates = SemanticCollector.collect(
            blocks,
            source: markdown as NSString,
            registry: registry
        )
        let spans = candidates.compactMap { candidate -> MarkdownAccessibilitySpan? in
            guard let visibleRange = text.visibleRange(for: candidate.range) else { return nil }
            return MarkdownAccessibilitySpan(
                sourceRange: candidate.range,
                visibleRange: visibleRange,
                role: candidate.role
            )
        }.sorted {
            if $0.visibleRange.location != $1.visibleRange.location {
                return $0.visibleRange.location < $1.visibleRange.location
            }
            return $0.visibleRange.length > $1.visibleRange.length
        }
        return MarkdownAccessibilityProjection(text: text, spans: spans)
    }
}

private enum SemanticCollector {
    struct Candidate {
        let range: NSRange
        let role: MarkdownAccessibilityRole
    }

    struct ReferenceDefinition {
        let destination: String
    }

    static func collect(
        _ blocks: [BlockNode],
        source: NSString,
        registry: ExtensionRegistry
    ) -> [Candidate] {
        let linkDefinitions = referenceDefinitions(in: blocks, source: source)
        let footnoteDefinitions = Set(blocks.compactMap { block -> String? in
            guard case .footnoteDefinition(_, let label, _, _) = block else { return nil }
            return source.substring(with: label).lowercased()
        })
        var result: [Candidate] = []
        for block in blocks {
            collect(
                block,
                source: source,
                registry: registry,
                linkDefinitions: linkDefinitions,
                footnoteDefinitions: footnoteDefinitions,
                into: &result
            )
        }
        return result
    }

    private static func referenceDefinitions(
        in blocks: [BlockNode],
        source: NSString
    ) -> [String: ReferenceDefinition] {
        var result: [String: ReferenceDefinition] = [:]
        for block in blocks {
            guard case .linkDefinition(_, let label, let destination, _) = block else { continue }
            let key = MarkdownLinkSyntax.normalizedLabel(in: source, range: label)
            if result[key] == nil {
                result[key] = ReferenceDefinition(
                    destination: MarkdownLinkSyntax.unescapedText(
                        in: source,
                        range: destination
                    )
                )
            }
        }
        return result
    }

    private static func collect(
        _ block: BlockNode,
        source: NSString,
        registry: ExtensionRegistry,
        linkDefinitions: [String: ReferenceDefinition],
        footnoteDefinitions: Set<String>,
        into result: inout [Candidate]
    ) {
        switch block {
        case .footnoteDefinition(let range, let label, _, let inlines):
            result.append(Candidate(
                range: range,
                role: .footnoteDefinition(label: source.substring(with: label))
            ))
            collect(
                inlines,
                source: source,
                linkDefinitions: linkDefinitions,
                footnoteDefinitions: footnoteDefinitions,
                into: &result
            )

        case .paragraph(_, let inlines), .blockquote(_, let inlines):
            collect(
                inlines,
                source: source,
                linkDefinitions: linkDefinitions,
                footnoteDefinitions: footnoteDefinitions,
                into: &result
            )

        case .heading(let level, let range, _, let inlines):
            result.append(Candidate(range: range, role: .heading(level: level)))
            collect(
                inlines,
                source: source,
                linkDefinitions: linkDefinitions,
                footnoteDefinitions: footnoteDefinitions,
                into: &result
            )

        case .list(_, let items):
            for (index, item) in items.enumerated() {
                let prefix = item.ordered ? "\(item.number ?? index + 1)." : "•"
                result.append(Candidate(
                    range: item.contentRange,
                    role: .listItem(
                        level: item.level,
                        index: index,
                        prefix: prefix,
                        isChecked: item.checkbox == nil ? nil : item.checked
                    )
                ))
                collect(
                    item.inlines,
                    source: source,
                    linkDefinitions: linkDefinitions,
                    footnoteDefinitions: footnoteDefinitions,
                    into: &result
                )
            }

        case .table(let range):
            collect(
                InlineParser.parse(source, range: range, registry: registry),
                source: source,
                linkDefinitions: linkDefinitions,
                footnoteDefinitions: footnoteDefinitions,
                into: &result
            )

        case .ext(let node):
            collect(
                node.inlines,
                source: source,
                linkDefinitions: linkDefinitions,
                footnoteDefinitions: footnoteDefinitions,
                into: &result
            )

        case .frontmatter, .linkDefinition, .codeBlock, .thematicBreak, .blank:
            break
        }
    }

    private static func collect(
        _ nodes: [InlineNode],
        source: NSString,
        linkDefinitions: [String: ReferenceDefinition],
        footnoteDefinitions: Set<String>,
        into result: inout [Candidate]
    ) {
        for node in nodes {
            switch node {
            case .emphasis(_, _, _, let children):
                collect(
                    children,
                    source: source,
                    linkDefinitions: linkDefinitions,
                    footnoteDefinitions: footnoteDefinitions,
                    into: &result
                )

            case .link(_, let textRange, let url, _, _, let children):
                result.append(Candidate(
                    range: textRange,
                    role: .link(destination: MarkdownLinkSyntax.unescapedText(
                        in: source,
                        range: url
                    ))
                ))
                collect(
                    children,
                    source: source,
                    linkDefinitions: linkDefinitions,
                    footnoteDefinitions: footnoteDefinitions,
                    into: &result
                )

            case .image(_, let alt, let url, _, _):
                result.append(Candidate(
                    range: alt,
                    role: .image(
                        label: source.substring(with: alt),
                        destination: MarkdownLinkSyntax.unescapedText(in: source, range: url)
                    )
                ))

            case .referenceLink(_, let textRange, let label, _, let children):
                let key = MarkdownLinkSyntax.normalizedLabel(
                    in: source,
                    range: label ?? textRange
                )
                if let definition = linkDefinitions[key] {
                    result.append(Candidate(
                        range: textRange,
                        role: .link(destination: definition.destination)
                    ))
                }
                collect(
                    children,
                    source: source,
                    linkDefinitions: linkDefinitions,
                    footnoteDefinitions: footnoteDefinitions,
                    into: &result
                )

            case .footnoteReference(_, let label, _):
                let id = source.substring(with: label)
                if footnoteDefinitions.contains(id.lowercased()) {
                    result.append(Candidate(
                        range: label,
                        role: .footnoteReference(label: id)
                    ))
                }

            case .autolink(_, let url, _):
                result.append(Candidate(
                    range: url,
                    role: .link(destination: source.substring(with: url))
                ))

            case .ext(let node):
                collect(
                    node.children,
                    source: source,
                    linkDefinitions: linkDefinitions,
                    footnoteDefinitions: footnoteDefinitions,
                    into: &result
                )

            case .text, .code, .hardBreak, .escape:
                break
            }
        }
    }
}

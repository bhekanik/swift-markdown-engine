//
//  InlineParser.swift
//  MarkdownEngine
//
//  Phase 2 of the regex→AST refactor: the inline-structure pass. Given the
//  text of a single inline-bearing block, it produces an inline AST node tree
//  with correct CommonMark precedence — replacing the per-construct regex soup
//  that the current tokenizer uses inside each block.
//
//  Built construct by construct, test-first. Ranges in the returned tree are
//  relative to the parsed string; callers offset to document coordinates.
//
//  Pipeline (each pass claims spans only in regions not already claimed, so
//  there are never partial overlaps and buildTree is a clean containment tree):
//    1. scanCodeSpans   — highest precedence, opaque interior.
//    2. scanEscapes      — `\x` becomes a claimed span, so the escaped char is
//                          automatically inert for every pass below.
//    3. scanLinkFamily   — inline links, reference links, footnotes,
//                          autolinks, images, and registered extension spans.
//                          A candidate overlapping a claimed span is rejected
//                          except where escapes are inert inside link content.
//    4. scanHardBreaks   — line-ending marker runs outside claimed spans.
//    5. resolveEmphasis  — `*`/`_` delimiter runs over text outside every
//                          claimed span; may wrap claimed spans.
//    6. buildTree        — containment tree. Emphasis nests already-collected
//                          spans; link/extension-span content is re-parsed
//                          recursively; the remaining claims are opaque leaves.
//
//  Claimed spans are therefore either disjoint or properly NESTED — a link
//  label may hold one, nothing else may. That is load-bearing for cost as well
//  as correctness: it's what lets `ClaimedIndex` answer "is this claimed?" with
//  a cursor and `buildTree` derive containment from a sort. A pass that claimed
//  a PARTIALLY overlapping span would break both, so keep claiming whole or not
//  at all.
//

import Foundation

enum EmphasisKind: Equatable { case italic, bold, boldItalic }

/// A node in the inline AST.
indirect enum InlineNode: Equatable {
    case text(NSRange)
    /// `` `code` `` — opaque; `range` covers the backticks, `content` strips single-space padding.
    case code(range: NSRange, content: NSRange)
    /// `*`/`_` emphasis. `markers` is `[openMarker, closeMarker]`.
    case emphasis(EmphasisKind, range: NSRange, markers: [NSRange], children: [InlineNode])
    /// `[text](url "title")`; text is recursively parsed.
    case link(range: NSRange, textRange: NSRange, url: NSRange, title: NSRange?, markers: [NSRange], children: [InlineNode])
    /// `![alt](url "title")`. Alt is opaque.
    case image(range: NSRange, alt: NSRange, url: NSRange, title: NSRange?, markers: [NSRange])
    /// `![alt][id]`, `![alt][]`, or shortcut `![alt]`.
    case referenceImage(range: NSRange, alt: NSRange, label: NSRange?, markers: [NSRange], children: [InlineNode])
    /// `[text][id]`, `[text][]`, or shortcut `[id]`; text is recursively parsed.
    case referenceLink(range: NSRange, textRange: NSRange, label: NSRange?, markers: [NSRange], children: [InlineNode])
    /// `[^id]`; `label` excludes the `[^` and `]` markers.
    case footnoteReference(range: NSRange, label: NSRange, markers: [NSRange])
    /// A backslash or two-or-more spaces immediately before an internal line ending.
    case hardBreak(range: NSRange, marker: NSRange)
    /// `<absolute-uri>` or `<email@example.com>`.
    case autolink(range: NSRange, url: NSRange, markers: [NSRange])
    /// Backslash escape `\x`; `marker` is the `\`, `character` the now-literal punctuation.
    case escape(range: NSRange, character: NSRange, marker: NSRange)
    /// A span contributed by a registered `MarkdownExtension`
    /// (e.g. `==highlight==`). Pure data — behavior lives in the extension,
    /// looked up by `extensionID` at styling/render time.
    case ext(ExtensionInlineNode)
}

/// An extension-contributed inline span. `children` is empty for opaque
/// (non-`parsesContent`) spans.
struct ExtensionInlineNode: Equatable {
    let extensionID: String
    let range: NSRange
    let contentRange: NSRange
    let markers: [NSRange]   // [open, close]
    let children: [InlineNode]
}

enum InlineParser {

    private static let backtick: unichar = 0x60
    private static let asterisk: unichar = 0x2A
    private static let underscore: unichar = 0x5F
    private static let newline: unichar = 0x0A
    private static let bang: unichar = 0x21
    private static let lbracket: unichar = 0x5B
    private static let rbracket: unichar = 0x5D
    private static let lparen: unichar = 0x28
    private static let rparen: unichar = 0x29
    private static let backslash: unichar = 0x5C
    private static let carriageReturn: unichar = 0x0D
    private static let langle: unichar = 0x3C
    private static let rangle: unichar = 0x3E
    private static let caret: unichar = 0x5E

    // MARK: - Entry point

    static func parse(
        _ text: String,
        registry: ExtensionRegistry = .empty,
        referenceDefinitions: Set<String> = []
    ) -> [InlineNode] {
        let ns = text as NSString
        let len = ns.length
        guard len > 0 else { return [] }

        var claimed = scanCodeSpans(ns, len: len)
        claimed += scanEscapes(ns, len: len, claimed: ClaimedIndex(claimed))
        claimed += scanLinkFamily(
            ns,
            len: len,
            claimed: ClaimedIndex(claimed),
            registry: registry,
            referenceDefinitions: referenceDefinitions
        )
        claimed += scanHardBreaks(ns, len: len, claimed: ClaimedIndex(claimed))
        let emphasis = resolveEmphasis(ns, len: len, claimed: ClaimedIndex(claimed))
        return buildTree(
            region: NSRange(location: 0, length: len),
            spans: claimed + emphasis,
            ns: ns,
            registry: registry,
            referenceDefinitions: referenceDefinitions
        )
    }

    /// Parse the inline content of `range` within `ns`, returning nodes in absolute document coordinates.
    static func parse(
        _ ns: NSString,
        range: NSRange,
        registry: ExtensionRegistry = .empty,
        referenceDefinitions: Set<String> = []
    ) -> [InlineNode] {
        offsetNodes(parse(
            ns.substring(with: range),
            registry: registry,
            referenceDefinitions: referenceDefinitions
        ), by: range.location)
    }

    // MARK: - Span model

    private enum Span {
        case code(range: NSRange, content: NSRange)
        case emphasis(kind: EmphasisKind, range: NSRange, open: NSRange, close: NSRange)
        case link(range: NSRange, textRange: NSRange, url: NSRange, title: NSRange?, markers: [NSRange])
        case image(range: NSRange, alt: NSRange, url: NSRange, title: NSRange?, markers: [NSRange])
        case referenceImage(range: NSRange, alt: NSRange, label: NSRange?, markers: [NSRange])
        case referenceLink(range: NSRange, textRange: NSRange, label: NSRange?, markers: [NSRange])
        case footnoteReference(range: NSRange, label: NSRange, markers: [NSRange])
        case hardBreak(range: NSRange, marker: NSRange)
        case autolink(range: NSRange, url: NSRange, markers: [NSRange])
        case rawHTML(range: NSRange)
        case escape(range: NSRange, character: NSRange, marker: NSRange)
        case ext(id: String, range: NSRange, contentRange: NSRange, markers: [NSRange], parsesContent: Bool)

        var fullRange: NSRange {
            switch self {
            case .code(let r, _), .emphasis(_, let r, _, _), .link(let r, _, _, _, _),
                 .image(let r, _, _, _, _), .referenceImage(let r, _, _, _),
                 .referenceLink(let r, _, _, _),
                 .footnoteReference(let r, _, _), .hardBreak(let r, _),
                 .autolink(let r, _, _),
                 .rawHTML(let r),
                 .escape(let r, _, _),
                 .ext(_, let r, _, _, _):
                return r
            }
        }
    }

    /// The already-claimed ranges, in a form the later passes can consult in
    /// amortised constant time.
    ///
    /// Every pass that asks "is this claimed?" walks the string left to right
    /// and never looks back, and claimed ranges never PARTIALLY overlap (each
    /// pass only claims inside regions no earlier pass took). So a cursor over
    /// the sorted ranges answers without rescanning: the answer for index `i`
    /// only ever involves the first range that ends after `i`.
    ///
    /// A nested range (a code span inside a link label) sorts after its
    /// container, which already covers it, so `contains` stays correct without
    /// looking past the cursor. `overlapping` is the one query that must, and
    /// it peeks rather than advances.
    ///
    /// Sortedness is established here rather than assumed of callers, so no
    /// call site carries an ordering obligation.
    private struct ClaimedIndex {
        private let ranges: [NSRange]
        private var cursor = 0

        init(_ spans: [Span]) {
            ranges = spans.map(\.fullRange).sorted { $0.location < $1.location }
        }

        /// Discard ranges that end at or before `idx`. `idx` must not move backwards.
        private mutating func advance(to idx: Int) {
            while cursor < ranges.count, NSMaxRange(ranges[cursor]) <= idx { cursor += 1 }
        }

        mutating func contains(_ idx: Int) -> Bool {
            advance(to: idx)
            return cursor < ranges.count && NSLocationInRange(idx, ranges[cursor])
        }

        mutating func overlaps(_ range: NSRange) -> Bool {
            advance(to: range.location)
            return cursor < ranges.count && ranges[cursor].location < NSMaxRange(range)
        }

        /// Every claimed range overlapping `range`. Peeks forward from the
        /// cursor without consuming, so the caller's left-to-right walk is
        /// unaffected.
        mutating func overlapping(_ range: NSRange) -> [NSRange] {
            advance(to: range.location)
            var out: [NSRange] = []
            var k = cursor
            while k < ranges.count, ranges[k].location < NSMaxRange(range) {
                if NSIntersectionRange(ranges[k], range).length > 0 { out.append(ranges[k]) }
                k += 1
            }
            return out
        }
    }

    // MARK: - 1. Code spans

    private static func scanCodeSpans(_ ns: NSString, len: Int) -> [Span] {
        var spans: [Span] = []
        var i = 0
        while i < len {
            guard ns.character(at: i) == backtick, !isEscaped(i, ns) else { i += 1; continue }
            let runStart = i
            var j = i
            while j < len, ns.character(at: j) == backtick { j += 1 }
            let runLen = j - runStart
            guard let close = closingBacktickRun(in: ns, from: j, length: len, runLen: runLen) else {
                i = j; continue
            }
            let codeRange = NSRange(location: runStart, length: (close + runLen) - runStart)
            let rawContent = NSRange(location: j, length: close - j)
            spans.append(.code(range: codeRange, content: strippedCodeContent(rawContent, in: ns)))
            i = close + runLen
        }
        return spans
    }

    private static func closingBacktickRun(in ns: NSString, from: Int, length len: Int, runLen: Int) -> Int? {
        var k = from
        while k < len {
            guard ns.character(at: k) == backtick, !isEscaped(k, ns) else { k += 1; continue }
            let start = k
            while k < len, ns.character(at: k) == backtick { k += 1 }
            if k - start == runLen { return start }
        }
        return nil
    }

    private static func strippedCodeContent(_ raw: NSRange, in ns: NSString) -> NSRange {
        let space: unichar = 0x20
        guard raw.length >= 2,
              ns.character(at: raw.location) == space,
              ns.character(at: NSMaxRange(raw) - 1) == space else { return raw }
        var allSpaces = true
        for k in raw.location..<NSMaxRange(raw) where ns.character(at: k) != space {
            allSpaces = false; break
        }
        guard !allSpaces else { return raw }
        return NSRange(location: raw.location + 1, length: raw.length - 2)
    }

    // MARK: - 2. Backslash escapes (claimed → escaped chars are inert everywhere)

    private static func scanEscapes(_ ns: NSString, len: Int, claimed: ClaimedIndex) -> [Span] {
        var claimed = claimed
        var spans: [Span] = []
        var i = 0
        while i < len - 1 {
            if ns.character(at: i) == backslash, !claimed.contains(i), isAsciiPunctuationChar(ns.character(at: i + 1)) {
                spans.append(.escape(
                    range: NSRange(location: i, length: 2),
                    character: NSRange(location: i + 1, length: 1),
                    marker: NSRange(location: i, length: 1)
                ))
                i += 2   // the escaped char can't itself start a new escape (even/odd `\\`)
            } else {
                i += 1
            }
        }
        return spans
    }

    // MARK: - 3. Link family / extension spans

    private static func scanLinkFamily(
        _ ns: NSString,
        len: Int,
        claimed: ClaimedIndex,
        registry: ExtensionRegistry,
        referenceDefinitions: Set<String>
    ) -> [Span] {
        var claimed = claimed
        // A candidate overlapping a claimed span is rejected unless that escape
        // is meaningful inside the candidate. Those cases need the full overlap
        // list; everything else short-circuits on the first one.
        func hasDisallowedClaimedOverlap(_ span: Span) -> Bool {
            let allowedRanges: [NSRange]
            switch span {
            case .link(_, let textRange, let url, let title, _):
                allowedRanges = [textRange, url] + (title.map { [$0] } ?? [])
            case .image(_, let alt, let url, let title, _):
                allowedRanges = [alt, url] + (title.map { [$0] } ?? [])
            case .referenceImage(_, let alt, let label, _):
                allowedRanges = [alt] + (label.map { [$0] } ?? [])
            case .referenceLink(_, let textRange, let label, _):
                allowedRanges = [textRange] + (label.map { [$0] } ?? [])
            case .autolink:
                // Backslashes have no escape semantics inside autolinks, including before `>`.
                allowedRanges = [span.fullRange]
            default:
                allowedRanges = []
            }
            guard !allowedRanges.isEmpty else { return claimed.overlaps(span.fullRange) }
            return claimed.overlapping(span.fullRange).contains { claimedRange in
                !allowedRanges.contains { rangeContains($0, claimedRange) }
            }
        }
        var spans: [Span] = []
        var i = 0
        while i < len {
            if claimed.contains(i) { i += 1; continue }
            if let span = matchClaimedSpan(
                ns,
                len,
                at: i,
                registry: registry,
                referenceDefinitions: referenceDefinitions
            ),
               !hasDisallowedClaimedOverlap(span) {
                spans.append(span)
                i = NSMaxRange(span.fullRange)
            } else {
                i += 1
            }
        }
        return spans
    }

    private static func matchClaimedSpan(
        _ ns: NSString,
        _ len: Int,
        at i: Int,
        registry: ExtensionRegistry,
        referenceDefinitions: Set<String>
    ) -> Span? {
        if let span = matchBuiltIn(
            ns,
            len,
            at: i,
            registry: registry,
            referenceDefinitions: referenceDefinitions
        ) { return span }
        // Extensions match after every built-in, in registration order.
        let c = ns.character(at: i)
        for entry in registry.entries where entry.open.first == c {
            if let span = matchExtensionSpan(ns, len, start: i, entry: entry) { return span }
        }
        return nil
    }

    /// The built-in constructs, tried exclusively in fixed precedence order —
    /// the first branch whose trigger matches decides (nil = stays literal
    /// for built-ins), exactly the pre-extension behavior.
    private static func matchBuiltIn(
        _ ns: NSString,
        _ len: Int,
        at i: Int,
        registry: ExtensionRegistry,
        referenceDefinitions: Set<String>
    ) -> Span? {
        let c = ns.character(at: i)
        let c1 = peek(ns, i + 1, len)
        if c == bang, c1 == lbracket {
            return matchImage(
                ns,
                len,
                start: i,
                registry: registry,
                referenceDefinitions: referenceDefinitions
            )
        }
        if c == lbracket, c1 == caret { return matchFootnoteReference(ns, len, start: i) }
        if c == lbracket {
            return matchLink(
                ns,
                len,
                start: i,
                registry: registry,
                referenceDefinitions: referenceDefinitions
            )
        }
        if c == langle {
            return matchAutolink(ns, len, start: i) ?? matchRawHTMLTag(ns, len, start: i)
        }
        return nil
    }

    /// Generic scanner for extension-contributed delimited spans. Mirrors the
    /// built-in `~~`/`==` semantics: the span opens at an exact `open` match,
    /// closes at the FIRST exact `close` match on the same line, and a lone
    /// occurrence of `close`'s first character inside the content aborts the
    /// candidate (it stays literal).
    private static func matchExtensionSpan(_ ns: NSString, _ len: Int, start i: Int, entry: ExtensionRegistry.Entry) -> Span? {
        let open = entry.open, close = entry.close
        guard !open.isEmpty, !close.isEmpty else { return nil }
        guard matches(ns, len, at: i, chars: open) else { return nil }
        if entry.syntax.rejectsOpenerRun, i > 0, ns.character(at: i - 1) == open[0] { return nil }

        let contentStart = i + open.count
        let closeFirst = close[0]
        var k = contentStart
        while k < len {
            let ch = ns.character(at: k)
            if ch == newline { return nil }
            if ch == closeFirst {
                guard matches(ns, len, at: k, chars: close) else { return nil }
                if entry.syntax.requiresNonEmptyContent, k == contentStart { return nil }
                if entry.syntax.rejectsCloserRun,
                   let after = peek(ns, k + close.count, len), after == close[close.count - 1] { return nil }
                return .ext(
                    id: entry.id,
                    range: NSRange(location: i, length: (k + close.count) - i),
                    contentRange: NSRange(location: contentStart, length: k - contentStart),
                    markers: [NSRange(location: i, length: open.count), NSRange(location: k, length: close.count)],
                    parsesContent: entry.syntax.parsesContent
                )
            }
            k += 1
        }
        return nil
    }

    /// Exact UTF-16 sequence match at `i`.
    private static func matches(_ ns: NSString, _ len: Int, at i: Int, chars: [unichar]) -> Bool {
        guard i + chars.count <= len else { return false }
        for (offset, u) in chars.enumerated() where ns.character(at: i + offset) != u { return false }
        return true
    }

    private static func peek(_ ns: NSString, _ idx: Int, _ len: Int) -> unichar? {
        (idx >= 0 && idx < len) ? ns.character(at: idx) : nil
    }

    /// `![ alt ]( url )`, `![ alt ][ label ]`, or shortcut `![ alt ]`.
    private static func matchImage(
        _ ns: NSString,
        _ len: Int,
        start i: Int,
        registry: ExtensionRegistry,
        referenceDefinitions: Set<String>
    ) -> Span? {
        let altStart = i + 2
        guard let closeBracket = closingLinkTextBracket(
            in: ns,
            from: altStart,
            end: len,
            registry: registry
        ) else {
            return nil
        }
        let alt = NSRange(location: altStart, length: closeBracket - altStart)

        if peek(ns, closeBracket + 1, len) == lparen,
           let parsed = MarkdownLinkSyntax.inlineTarget(in: ns, from: closeBracket + 2, length: len) {
            let closeParen = parsed.closeParen
            return .image(
                range: NSRange(location: i, length: (closeParen + 1) - i),
                alt: alt,
                url: parsed.target.destination,
                title: parsed.target.title,
                markers: [
                    NSRange(location: i, length: 2),
                    NSRange(location: closeBracket, length: 1),
                    NSRange(location: closeBracket + 1, length: 1),
                    NSRange(location: closeParen, length: 1),
                ] + parsed.target.markers
            )
        }

        if peek(ns, closeBracket + 1, len) == lbracket,
           let labelClose = MarkdownLinkSyntax.closingReferenceLabel(
               in: ns,
               from: closeBracket + 2,
               end: len
           ) {
            let explicitLabel = NSRange(
                location: closeBracket + 2,
                length: labelClose - closeBracket - 2
            )
            let definitionLabel = explicitLabel.length == 0 ? alt : explicitLabel
            guard referenceDefinitions.contains(
                MarkdownLinkSyntax.normalizedLabel(in: ns, range: definitionLabel)
            ) else { return nil }
            return .referenceImage(
                range: NSRange(location: i, length: labelClose + 1 - i),
                alt: alt,
                label: explicitLabel.length == 0 ? nil : explicitLabel,
                markers: [
                    NSRange(location: i, length: 2),
                    NSRange(location: closeBracket, length: 1),
                    NSRange(location: closeBracket + 1, length: 1),
                    NSRange(location: labelClose, length: 1),
                ]
            )
        }

        guard referenceDefinitions.contains(
            MarkdownLinkSyntax.normalizedLabel(in: ns, range: alt)
        ) else { return nil }
        return .referenceImage(
            range: NSRange(location: i, length: closeBracket + 1 - i),
            alt: alt,
            label: nil,
            markers: [NSRange(location: i, length: 2), NSRange(location: closeBracket, length: 1)]
        )
    }

    /// `[ text ]( url )`, `[ text ][ label ]`, or shortcut `[ label ]`.
    private static func matchLink(
        _ ns: NSString,
        _ len: Int,
        start i: Int,
        registry: ExtensionRegistry,
        referenceDefinitions: Set<String>
    ) -> Span? {
        let textStart = i + 1
        guard let closeBracket = closingLinkTextBracket(
            in: ns,
            from: textStart,
            end: len,
            registry: registry
        ),
              closeBracket > textStart else { return nil }
        let textRange = NSRange(location: textStart, length: closeBracket - textStart)

        if peek(ns, closeBracket + 1, len) == lparen,
           let parsed = MarkdownLinkSyntax.inlineTarget(in: ns, from: closeBracket + 2, length: len) {
            let closeParen = parsed.closeParen
            guard !containsLink(in: textRange, source: ns, referenceDefinitions: referenceDefinitions) else {
                return nil
            }
            return .link(
                range: NSRange(location: i, length: (closeParen + 1) - i),
                textRange: textRange,
                url: parsed.target.destination,
                title: parsed.target.title,
                markers: [
                    NSRange(location: i, length: 1),
                    NSRange(location: closeBracket, length: 1),
                    NSRange(location: closeBracket + 1, length: 1),
                    NSRange(location: closeParen, length: 1),
                ] + parsed.target.markers
            )
        }

        if peek(ns, closeBracket + 1, len) == lbracket,
           let labelClose = MarkdownLinkSyntax.closingReferenceLabel(
               in: ns,
               from: closeBracket + 2,
               end: len
           ) {
            let label = NSRange(location: closeBracket + 2, length: labelClose - closeBracket - 2)
            let definitionLabel = label.length == 0 ? textRange : label
            guard referenceDefinitions.contains(
                MarkdownLinkSyntax.normalizedLabel(in: ns, range: definitionLabel)
            ), !containsLink(
                in: textRange,
                source: ns,
                referenceDefinitions: referenceDefinitions
            ) else { return nil }
            return .referenceLink(
                range: NSRange(location: i, length: labelClose + 1 - i),
                textRange: textRange,
                label: label.length == 0 ? nil : label,
                markers: [
                    NSRange(location: i, length: 1),
                    NSRange(location: closeBracket, length: 1),
                    NSRange(location: closeBracket + 1, length: 1),
                    NSRange(location: labelClose, length: 1),
                ]
            )
        }

        guard referenceDefinitions.contains(
            MarkdownLinkSyntax.normalizedLabel(in: ns, range: textRange)
        ), !containsLink(
            in: textRange,
            source: ns,
            referenceDefinitions: referenceDefinitions
        ) else { return nil }
        return .referenceLink(
            range: NSRange(location: i, length: closeBracket + 1 - i),
            textRange: textRange,
            label: nil,
            markers: [NSRange(location: i, length: 1), NSRange(location: closeBracket, length: 1)]
        )
    }

    private static func closingLinkTextBracket(
        in ns: NSString,
        from start: Int,
        end: Int,
        registry: ExtensionRegistry
    ) -> Int? {
        var depth = 0
        var i = start
        scan: while i < end {
            let character = ns.character(at: i)
            if character == newline || character == carriageReturn { return nil }
            if !isEscaped(i, ns) {
                for entry in registry.entries where entry.open.first == character {
                    if let span = matchExtensionSpan(ns, end, start: i, entry: entry) {
                        i = NSMaxRange(span.fullRange)
                        continue scan
                    }
                }
                if character == langle {
                    var angleClose = i + 1
                    while angleClose < end {
                        let angleCharacter = ns.character(at: angleClose)
                        if angleCharacter == newline || angleCharacter == carriageReturn { break }
                        if angleCharacter == rangle {
                            i = angleClose + 1
                            continue scan
                        }
                        angleClose += 1
                    }
                } else if character == lbracket {
                    depth += 1
                } else if character == rbracket {
                    if depth == 0 { return i }
                    depth -= 1
                }
            }
            i += 1
        }
        return nil
    }

    private static func containsLink(
        in range: NSRange,
        source: NSString,
        referenceDefinitions: Set<String>
    ) -> Bool {
        containsLink(parse(
            source.substring(with: range),
            referenceDefinitions: referenceDefinitions
        ))
    }

    private static func containsLink(_ nodes: [InlineNode]) -> Bool {
        nodes.contains { node in
            switch node {
            case .link, .referenceLink, .autolink:
                return true
            case .emphasis(_, _, _, let children):
                return containsLink(children)
            case .ext(let node):
                return containsLink(node.children)
            default:
                return false
            }
        }
    }

    static func plainText(_ nodes: [InlineNode], source: NSString) -> String {
        nodes.map { node in
            switch node {
            case .text(let range):
                return source.substring(with: range)
            case .code(_, let content):
                return source.substring(with: content)
            case .emphasis(_, _, _, let children),
                 .link(_, _, _, _, _, let children),
                 .referenceLink(_, _, _, _, let children),
                 .referenceImage(_, _, _, _, let children):
                return plainText(children, source: source)
            case .image(_, let alt, _, _, _):
                return MarkdownLinkSyntax.unescapedText(in: source, range: alt)
            case .footnoteReference(_, let label, _),
                 .autolink(_, let label, _):
                return source.substring(with: label)
            case .hardBreak:
                return "\n"
            case .escape(_, let character, _):
                return source.substring(with: character)
            case .ext(let node):
                return node.children.isEmpty
                    ? source.substring(with: node.contentRange)
                    : plainText(node.children, source: source)
            }
        }.joined()
    }

    private static func matchFootnoteReference(_ ns: NSString, _ len: Int, start i: Int) -> Span? {
        let labelStart = i + 2
        guard let close = findChar(ns, len, from: labelStart, char: rbracket),
              close > labelStart else { return nil }
        return .footnoteReference(
            range: NSRange(location: i, length: close + 1 - i),
            label: NSRange(location: labelStart, length: close - labelStart),
            markers: [NSRange(location: i, length: 2), NSRange(location: close, length: 1)]
        )
    }

    private static let uriAutolink = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\x00-\x20<>]*$"#
    )
    private static let emailAutolink = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"#
    )
    private static let rawHTMLTag = try! NSRegularExpression(
        pattern: #"<[A-Za-z][A-Za-z0-9-]*(?:[ \t]+[A-Za-z_:][A-Za-z0-9_.:-]*(?:[ \t]*=[ \t]*(?:[^ \t\"'=<>`]+|'[^']*'|\"[^\"]*\"))?)*[ \t]*/?>"#
    )

    private static func matchRawHTMLTag(_ ns: NSString, _ len: Int, start i: Int) -> Span? {
        guard let match = rawHTMLTag.firstMatch(
            in: ns as String,
            options: .anchored,
            range: NSRange(location: i, length: len - i)
        ) else { return nil }
        return .rawHTML(range: match.range)
    }

    private static func matchAutolink(_ ns: NSString, _ len: Int, start i: Int) -> Span? {
        var close = i + 1
        while close < len,
              ns.character(at: close) != rangle,
              ns.character(at: close) != newline,
              ns.character(at: close) != carriageReturn {
            close += 1
        }
        guard close < len, ns.character(at: close) == rangle else { return nil }
        let url = NSRange(location: i + 1, length: close - i - 1)
        guard url.length > 0 else { return nil }
        let value = ns.substring(with: url)
        let whole = NSRange(location: 0, length: (value as NSString).length)
        guard uriAutolink.firstMatch(in: value, range: whole)?.range == whole
                || emailAutolink.firstMatch(in: value, range: whole)?.range == whole else { return nil }
        return .autolink(
            range: NSRange(location: i, length: close + 1 - i),
            url: url,
            markers: [NSRange(location: i, length: 1), NSRange(location: close, length: 1)]
        )
    }

    private static func findChar(_ ns: NSString, _ len: Int, from: Int, char: unichar) -> Int? {
        var k = from
        while k < len {
            let ch = ns.character(at: k)
            if ch == char, !isEscaped(k, ns) { return k }
            if ch == newline || ch == carriageReturn { return nil }
            k += 1
        }
        return nil
    }

    // MARK: - 4. Hard line breaks

    private static func scanHardBreaks(_ ns: NSString, len: Int, claimed: ClaimedIndex) -> [Span] {
        var claimed = claimed
        var spans: [Span] = []
        var i = 0
        while i < len {
            let c = ns.character(at: i)
            guard c == newline || c == carriageReturn else { i += 1; continue }
            let next = c == carriageReturn && i + 1 < len && ns.character(at: i + 1) == newline ? i + 2 : i + 1
            guard next < len else { i = next; continue }

            var marker: NSRange?
            if i > 0, ns.character(at: i - 1) == backslash, !isEscaped(i - 1, ns) {
                marker = NSRange(location: i - 1, length: 1)
            } else {
                var start = i
                while start > 0, ns.character(at: start - 1) == 0x20 { start -= 1 }
                if i - start >= 2 { marker = NSRange(location: start, length: i - start) }
            }
            if let marker, !claimed.overlaps(marker) {
                spans.append(.hardBreak(
                    range: NSRange(location: marker.location, length: next - marker.location),
                    marker: marker
                ))
            }
            i = next
        }
        return spans
    }

    // MARK: - 5. Emphasis (delimiter runs)

    private struct DelimRun {
        let char: unichar
        let originalLength: Int
        var leftEdge: Int
        var rightEdge: Int
        let canOpen: Bool
        let canClose: Bool
        let lineIdx: Int
        var remaining: Int { rightEdge - leftEdge }
    }

    private static func resolveEmphasis(_ ns: NSString, len: Int, claimed: ClaimedIndex) -> [Span] {
        var runs = collectDelimiterRuns(ns, len: len, claimed: claimed)
        guard !runs.isEmpty else { return [] }
        var stack: [Int] = []
        var spans: [Span] = []
        for idx in runs.indices {
            if runs[idx].canClose {
                closeAgainstStack(closerIdx: idx, runs: &runs, stack: &stack, spans: &spans)
            }
            if runs[idx].canOpen && runs[idx].remaining > 0 {
                stack.append(idx)
            }
        }
        return spans
    }

    private static func collectDelimiterRuns(_ ns: NSString, len: Int, claimed: ClaimedIndex) -> [DelimRun] {
        var claimed = claimed
        var runs: [DelimRun] = []
        var lineIdx = 0
        var i = 0
        while i < len {
            let c = ns.character(at: i)
            if c == newline { lineIdx += 1; i += 1; continue }
            guard c == asterisk || c == underscore, !claimed.contains(i) else { i += 1; continue }
            var j = i
            while j < len, ns.character(at: j) == c { j += 1 }

            let before = i - 1, after = j
            let beforeWs = isWhitespaceOrBoundary(before, ns, len)
            let beforePunct = isAsciiPunctuation(before, ns, len)
            let afterWs = isWhitespaceOrBoundary(after, ns, len)
            let afterPunct = isAsciiPunctuation(after, ns, len)
            let leftFlanking = !afterWs && (!afterPunct || beforeWs || beforePunct)
            let rightFlanking = !beforeWs && (!beforePunct || afterWs || afterPunct)

            let canOpen: Bool, canClose: Bool
            if c == underscore {
                canOpen = leftFlanking && (!rightFlanking || beforePunct)
                canClose = rightFlanking && (!leftFlanking || afterPunct)
            } else {
                canOpen = leftFlanking
                canClose = rightFlanking
            }
            runs.append(DelimRun(
                char: c, originalLength: j - i, leftEdge: i, rightEdge: j,
                canOpen: canOpen, canClose: canClose, lineIdx: lineIdx
            ))
            i = j
        }
        return runs
    }

    private static func closeAgainstStack(
        closerIdx: Int, runs: inout [DelimRun], stack: inout [Int], spans: inout [Span]
    ) {
        var sp = stack.count - 1
        while sp >= 0, runs[closerIdx].remaining > 0 {
            let openerIdx = stack[sp]
            if runs[openerIdx].char != runs[closerIdx].char { sp -= 1; continue }
            if runs[openerIdx].lineIdx != runs[closerIdx].lineIdx {
                stack.remove(at: sp); sp -= 1; continue
            }
            let avail = min(runs[openerIdx].remaining, runs[closerIdx].remaining)
            if avail == 0 { stack.remove(at: sp); sp -= 1; continue }

            let openerBoth = runs[openerIdx].canOpen && runs[openerIdx].canClose
            let closerBoth = runs[closerIdx].canOpen && runs[closerIdx].canClose
            if openerBoth || closerBoth {
                let sum = runs[openerIdx].originalLength + runs[closerIdx].originalLength
                let bothMod3 = runs[openerIdx].originalLength % 3 == 0 && runs[closerIdx].originalLength % 3 == 0
                if sum % 3 == 0 && !bothMod3 { sp -= 1; continue }
            }

            let matchLen = avail >= 3 ? 3 : (avail >= 2 ? 2 : 1)
            let openerMarkerStart = runs[openerIdx].rightEdge - matchLen
            let closerMarkerStart = runs[closerIdx].leftEdge
            let kind: EmphasisKind = matchLen == 3 ? .boldItalic : (matchLen == 2 ? .bold : .italic)

            spans.append(.emphasis(
                kind: kind,
                range: NSRange(location: openerMarkerStart, length: (closerMarkerStart + matchLen) - openerMarkerStart),
                open: NSRange(location: openerMarkerStart, length: matchLen),
                close: NSRange(location: closerMarkerStart, length: matchLen)
            ))

            runs[openerIdx].rightEdge -= matchLen
            runs[closerIdx].leftEdge += matchLen
            if runs[openerIdx].remaining == 0 { stack.remove(at: sp) }
            sp -= 1
        }
    }

    // MARK: - 6. Containment tree

    private static func buildTree(
        region: NSRange,
        spans: [Span],
        ns: NSString,
        registry: ExtensionRegistry,
        referenceDefinitions: Set<String>
    ) -> [InlineNode] {
        // Spans are non-overlapping or properly nested (each pass claims only
        // inside regions no earlier pass took), so ordering by start ascending
        // and length descending puts every span immediately after the one that
        // contains it. Containment then falls out of a single ordered walk,
        // instead of testing each span against every other span.
        let ordered = spans
            .filter { rangeContains(region, $0.fullRange) }
            .sorted { a, b in
                let (x, y) = (a.fullRange, b.fullRange)
                return x.location == y.location ? x.length > y.length : x.location < y.location
            }
        var cursor = 0
        return buildTree(
            region: region,
            ordered: ordered,
            cursor: &cursor,
            ns: ns,
            registry: registry,
            referenceDefinitions: referenceDefinitions
        )
    }

    /// Consumes spans from `cursor` for as long as they fall inside `region`,
    /// leaving `cursor` on the first span that doesn't.
    private static func buildTree(
        region: NSRange,
        ordered: [Span],
        cursor: inout Int,
        ns: NSString,
        registry: ExtensionRegistry,
        referenceDefinitions: Set<String>
    ) -> [InlineNode] {
        var result: [InlineNode] = []
        var textStart = region.location

        while cursor < ordered.count {
            let span = ordered[cursor]
            let fr = span.fullRange
            guard rangeContains(region, fr) else { break }
            cursor += 1

            if fr.location > textStart {
                result.append(.text(NSRange(location: textStart, length: fr.location - textStart)))
            }
            switch span {
            case .code(let range, let content):
                result.append(.code(range: range, content: content))
            case .emphasis(let kind, let range, let open, let close):
                let content = NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open))
                result.append(.emphasis(kind, range: range, markers: [open, close],
                                        children: buildTree(region: content, ordered: ordered,
                                                            cursor: &cursor, ns: ns, registry: registry,
                                                            referenceDefinitions: referenceDefinitions)))
            case .link(let range, let textRange, let url, let title, let markers):
                result.append(.link(range: range, textRange: textRange, url: url, title: title, markers: markers,
                                     children: reparse(textRange, ns: ns, registry: registry,
                                                       referenceDefinitions: referenceDefinitions)))
            case .image(let range, let alt, let url, let title, let markers):
                result.append(.image(range: range, alt: alt, url: url, title: title, markers: markers))
            case .referenceImage(let range, let alt, let label, let markers):
                result.append(.referenceImage(
                    range: range,
                    alt: alt,
                    label: label,
                    markers: markers,
                    children: reparse(
                        alt,
                        ns: ns,
                        registry: registry,
                        referenceDefinitions: referenceDefinitions
                    )
                ))
            case .referenceLink(let range, let textRange, let label, let markers):
                result.append(.referenceLink(range: range, textRange: textRange, label: label, markers: markers,
                                             children: reparse(textRange, ns: ns, registry: registry,
                                                               referenceDefinitions: referenceDefinitions)))
            case .footnoteReference(let range, let label, let markers):
                result.append(.footnoteReference(range: range, label: label, markers: markers))
            case .hardBreak(let range, let marker):
                result.append(.hardBreak(range: range, marker: marker))
            case .autolink(let range, let url, let markers):
                result.append(.autolink(range: range, url: url, markers: markers))
            case .rawHTML(let range):
                result.append(.text(range))
            case .escape(let range, let character, let marker):
                result.append(.escape(range: range, character: character, marker: marker))
            case .ext(let id, let range, let contentRange, let markers, let parsesContent):
                result.append(.ext(ExtensionInlineNode(
                    extensionID: id, range: range, contentRange: contentRange, markers: markers,
                    children: parsesContent
                        ? reparse(contentRange, ns: ns, registry: registry,
                                  referenceDefinitions: referenceDefinitions)
                        : []
                )))
            }
            // Every span but emphasis is opaque, so nothing should remain
            // inside one. Skipping keeps the walk well-formed if that ever
            // changes, rather than emitting a node past the cursor.
            while cursor < ordered.count, rangeContains(fr, ordered[cursor].fullRange) { cursor += 1 }
            textStart = NSMaxRange(fr)
        }
        if textStart < NSMaxRange(region) {
            result.append(.text(NSRange(location: textStart, length: NSMaxRange(region) - textStart)))
        }
        return result
    }

    /// Recursively parse a sub-range's content, offset back to absolute coordinates.
    private static func reparse(
        _ range: NSRange,
        ns: NSString,
        registry: ExtensionRegistry,
        referenceDefinitions: Set<String>
    ) -> [InlineNode] {
        offsetNodes(parse(
            ns.substring(with: range),
            registry: registry,
            referenceDefinitions: referenceDefinitions
        ), by: range.location)
    }

    // MARK: - Helpers

    private static func offsetNodes(_ nodes: [InlineNode], by delta: Int) -> [InlineNode] {
        nodes.map { offset($0, by: delta) }
    }

    private static func offset(_ node: InlineNode, by d: Int) -> InlineNode {
        func s(_ r: NSRange) -> NSRange { NSRange(location: r.location + d, length: r.length) }
        switch node {
        case .text(let r): return .text(s(r))
        case .code(let r, let c): return .code(range: s(r), content: s(c))
        case .emphasis(let k, let r, let m, let ch): return .emphasis(k, range: s(r), markers: m.map(s), children: offsetNodes(ch, by: d))
        case .link(let r, let tr, let u, let t, let m, let ch): return .link(range: s(r), textRange: s(tr), url: s(u), title: t.map(s), markers: m.map(s), children: offsetNodes(ch, by: d))
        case .image(let r, let a, let u, let t, let m): return .image(range: s(r), alt: s(a), url: s(u), title: t.map(s), markers: m.map(s))
        case .referenceImage(let r, let a, let l, let m, let ch):
            return .referenceImage(
                range: s(r), alt: s(a), label: l.map(s), markers: m.map(s),
                children: offsetNodes(ch, by: d)
            )
        case .referenceLink(let r, let tr, let l, let m, let ch): return .referenceLink(range: s(r), textRange: s(tr), label: l.map(s), markers: m.map(s), children: offsetNodes(ch, by: d))
        case .footnoteReference(let r, let l, let m): return .footnoteReference(range: s(r), label: s(l), markers: m.map(s))
        case .hardBreak(let r, let m): return .hardBreak(range: s(r), marker: s(m))
        case .autolink(let r, let u, let m): return .autolink(range: s(r), url: s(u), markers: m.map(s))
        case .escape(let r, let c, let m): return .escape(range: s(r), character: s(c), marker: s(m))
        case .ext(let n): return .ext(ExtensionInlineNode(
            extensionID: n.extensionID, range: s(n.range), contentRange: s(n.contentRange),
            markers: n.markers.map(s), children: offsetNodes(n.children, by: d)))
        }
    }

    private static func rangeContains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private static func isWhitespaceOrBoundary(_ idx: Int, _ ns: NSString, _ len: Int) -> Bool {
        guard idx >= 0, idx < len else { return true }
        let c = ns.character(at: idx)
        return c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    private static func isAsciiPunctuation(_ idx: Int, _ ns: NSString, _ len: Int) -> Bool {
        guard idx >= 0, idx < len else { return false }
        return isAsciiPunctuationChar(ns.character(at: idx))
    }

    private static func isAsciiPunctuationChar(_ c: unichar) -> Bool {
        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40)
            || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }

    /// A character is backslash-escaped when preceded by an odd run of `\`.
    private static func isEscaped(_ idx: Int, _ ns: NSString) -> Bool {
        var count = 0
        var k = idx - 1
        while k >= 0, ns.character(at: k) == backslash { count += 1; k -= 1 }
        return count % 2 == 1
    }
}

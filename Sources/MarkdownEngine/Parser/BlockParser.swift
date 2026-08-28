//
//  BlockParser.swift
//  MarkdownEngine
//
//  Phase 1 of the regex→AST refactor: the block-structure pass. Splits the
//  document into a flat, gap-free (tiling) sequence of blocks following the
//  CommonMark two-phase model — block structure first, inline content later.
//  Inline parsing happens per inline-bearing block in a separate step.
//
//  Ranges are absolute UTF-16 NSRanges into the source (the editor is
//  NSTextView / TextKit-2 based, so UTF-16 offsets are the native currency).
//  Storing relative widths (green-tree style, for cheap incremental reparse)
//  is a deliberate Phase 3 concern and intentionally deferred here.
//
//  Line classification mirrors the recognition the current regex tokenizer /
//  styler perform, so block ranges line up with today's tokens:
//    • heading        — headingRegex        `^\s*#{1,6} +…`
//    • thematic break — styler HR pattern   `^\s*(-{3,}|\*{3,}|_{3,})\s*$`
//    • fenced code    — codeBlockRegex       opening/closing ``` line
//    • blockquote     — blockquoteRegex     `^[ \t]{0,3}(>…)`
//

import Foundation

/// The block-level classification of a run of lines.
enum BlockKind: Equatable {
    case frontmatter     // opening `---` through a closing `---` / `...`
    case linkDefinition  // consecutive `[id]: destination "title"` lines
    case footnoteDefinition // `[^id]: body` plus four-space continuation lines
    case paragraph       // inline-bearing
    case heading         // ATX or setext, inline-bearing content
    case blockquote      // consecutive `>` lines, inline-bearing per line
    case list            // consecutive list-item lines (`-`/`*`/`+` or `1.`/`1)`)
    case fencedCode      // fenced or indented code, opaque to inline parsing
    case table           // GFM table — opaque (rendered as a unit)
    case thematicBreak   // `---` / `***` / `___` — produces no token today
    case blank           // blank / whitespace-only line(s) — separator
    case ext(String)     // extension-supplied fenced block (id), inline-bearing content
}

/// One block; `range` is the absolute UTF-16 span of its lines, tiling with no gaps.
struct Block: Equatable {
    let kind: BlockKind
    let range: NSRange
}

/// A resolved contiguous change between two buffer states, in UTF-16 units.
/// `changeStart ..< changeEndOld` in the old buffer was replaced by
/// `changeStart ..< changeEndNew` in the new one. The region may be wider
/// than the minimal diff — splice logic only requires containment.
struct BufferDiff {
    let changeStart: Int
    let changeEndOld: Int
    let changeEndNew: Int
    let delta: Int
}

enum BlockParser {

    private static let cacheLock = NSLock()
    private static var cachedChars: [unichar]?     // UTF-16 buffer of the last parse
    private static var cachedBlocks: [Block]?
    /// Registry fingerprint the memo was computed under — extension fences
    /// change the block structure of identical text.
    private static var cachedFingerprint: String = ""

    /// Splits `text` into gap-free tiling blocks; memoizes the last parse so both per-keystroke callers share one line-scan.
    /// Pass `utf16Chars` when the caller already extracted the buffer (must match `text`).
    static func parse(_ text: String, utf16Chars: [unichar]? = nil, registry: ExtensionRegistry = .empty) -> [Block] {
        let textNS = text as NSString
        let newLen = textNS.length
        let newChars: [unichar]
        if let utf16Chars, utf16Chars.count == newLen {
            newChars = utf16Chars
        } else {
            var buffer = [unichar](repeating: 0, count: newLen)
            if newLen > 0 { textNS.getCharacters(&buffer, range: NSRange(location: 0, length: newLen)) }
            newChars = buffer
        }

        cacheLock.lock()
        let prevChars = cachedFingerprint == registry.fingerprint ? cachedChars : nil
        let prevBlocks = cachedFingerprint == registry.fingerprint ? cachedBlocks : nil
        cacheLock.unlock()

        if let prevChars, let prevBlocks {
            // Identical text → memcmp hit (the scan below would walk O(doc)).
            if equalBuffers(prevChars, newChars) { return prevBlocks }
            if let diff = scanDiff(old: prevChars, new: newChars),
               let (incr, _) = incrementalParse(oldChars: prevChars, oldBlocks: prevBlocks, newChars: newChars, newNS: textNS, diff: diff, registry: registry) {
                cacheLock.lock(); cachedChars = newChars; cachedBlocks = incr; cachedFingerprint = registry.fingerprint; cacheLock.unlock()
                return incr
            }
        }

        let blocks = computeBlocks(text, registry: registry)
        cacheLock.lock(); cachedChars = newChars; cachedBlocks = blocks; cachedFingerprint = registry.fingerprint; cacheLock.unlock()
        return blocks
    }

    /// Adopt an externally computed parse (DocumentParseState publishes its
    /// per-keystroke result) so static-path callers — the restyle's
    /// DocumentAST.parse above all — take the memcmp hit instead of
    /// re-splicing against a one-keystroke-stale cache.
    static func seedCache(chars: [unichar], blocks: [Block], fingerprint: String = "") {
        cacheLock.lock(); cachedChars = chars; cachedBlocks = blocks; cachedFingerprint = fingerprint; cacheLock.unlock()
    }

    private static func equalBuffers(_ a: [unichar], _ b: [unichar]) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        return a.withUnsafeBytes { ap in
            b.withUnsafeBytes { bp in memcmp(ap.baseAddress!, bp.baseAddress!, ap.count) == 0 }
        }
    }

    /// Common prefix/suffix scan; nil when the buffers are identical.
    static func scanDiff(old: [unichar], new: [unichar]) -> BufferDiff? {
        let oldLen = old.count, newLen = new.count
        var p = 0
        let maxPre = min(oldLen, newLen)
        while p < maxPre, old[p] == new[p] { p += 1 }
        if p == oldLen, oldLen == newLen { return nil }
        var s = 0
        let maxSuf = maxPre - p
        while s < maxSuf, old[oldLen - 1 - s] == new[newLen - 1 - s] { s += 1 }
        return BufferDiff(changeStart: p, changeEndOld: oldLen - s, changeEndNew: newLen - s, delta: newLen - oldLen)
    }

    /// Does any LINE touched by `[lo, hi)` contain a paired block delimiter? The
    /// boundary walk is capped; hitting the cap reports a delimiter
    /// (conservative full parse).
    static func hasBlockDelimiter(_ buf: [unichar], _ lo: Int, _ hi: Int, fences: [[unichar]] = []) -> Bool {
        let cap = 4096
        var start = max(0, lo - 3)
        var steps = 0
        while start > 0, buf[start - 1] != 0x0A, buf[start - 1] != 0x0D {
            start -= 1
            steps += 1
            if steps > cap { return true }
        }
        var end = min(buf.count, hi + 3)
        steps = 0
        while end < buf.count, buf[end] != 0x0A, buf[end] != 0x0D {
            end += 1
            steps += 1
            if steps > cap { return true }
        }
        var lineStart = start
        while lineStart < end {
            var lineEnd = lineStart
            while lineEnd < end, buf[lineEnd] != 0x0A, buf[lineEnd] != 0x0D { lineEnd += 1 }
            if isFrontmatterDelimiter(buf, from: lineStart, to: lineEnd) { return true }
            lineStart = lineEnd + 1
            if lineEnd < end, buf[lineEnd] == 0x0D,
               lineStart < end, buf[lineStart] == 0x0A {
                lineStart += 1
            }
        }
        var i = start
        while i < end {
            if buf[i] == 0x60, i + 2 < end, buf[i + 1] == 0x60, buf[i + 2] == 0x60 {
                return true                                              // ```
            }
            if buf[i] == 0x7E, i + 2 < end, buf[i + 1] == 0x7E, buf[i + 2] == 0x7E {
                return true                                              // ~~~
            }
            // Extension fences pair with a distant partner exactly like ``` —
            // an edit touching one must force the full reparse too.
            for fence in fences where !fence.isEmpty && buf[i] == fence[0] {
                if i + fence.count <= end {
                    var match = true
                    for (k, u) in fence.enumerated() where buf[i + k] != u { match = false; break }
                    if match { return true }
                }
            }
            i += 1
        }
        return false
    }

    /// Splice-parse against a precomputed change region (descriptor- or scan-derived):
    /// reparse the affected block window, splice between untouched prefix/suffix; nil to fall back to full.
    static func incrementalParse(oldChars o: [unichar], oldBlocks: [Block], newChars n: [unichar], newNS: NSString, diff: BufferDiff, registry: ExtensionRegistry = .empty) -> (blocks: [Block], window: Int)? {
        guard !oldBlocks.isEmpty else { return nil }
        let oldLen = o.count, newLen = n.count
        guard oldLen > 0, newLen > 0 else { return nil }

        let delta = diff.delta
        let changeStart = diff.changeStart
        let changeEnd = diff.changeEndOld       // [changeStart, changeEnd) in old
        guard changeStart >= 0, changeEnd <= oldLen, diff.changeEndNew <= newLen,
              changeStart <= changeEnd, changeStart <= diff.changeEndNew else { return nil }

        // A fence or extension delimiter in the edit can pair with a distant partner → full reparse.
        let fences = registry.blockEntries.map(\.fenceChars)
        if hasBlockDelimiter(o, changeStart, changeEnd, fences: fences)
            || hasBlockDelimiter(n, changeStart, diff.changeEndNew, fences: fences) {
            return nil
        }

        // 2. Affected old-block window (±1 block margin for merges/splits).
        // Blocks tile the document in order — binary search instead of the
        // linear walks that cost O(#blocks) per keystroke in large documents.
        var lo = 0, hi = oldBlocks.count - 1
        while lo < hi {                       // last block starting <= changeStart
            let m = (lo + hi + 1) / 2
            if oldBlocks[m].range.location <= changeStart { lo = m } else { hi = m - 1 }
        }
        let firstIdx = lo
        lo = 0; hi = oldBlocks.count - 1
        while lo < hi {                       // first block ending >= changeEnd
            let m = (lo + hi) / 2
            if NSMaxRange(oldBlocks[m].range) >= changeEnd { hi = m } else { lo = m + 1 }
        }
        let lastIdx = lo
        let winFirst = max(0, min(firstIdx, lastIdx) - 1)
        var winLast = min(oldBlocks.count - 1, max(firstIdx, lastIdx) + 1)

        // 3. Opaque multi-line fenced blocks in the window are fine for
        // INTERIOR edits: the window contains each block wholly, the ±3
        // delimiter guard above already bailed on any edit that creates,
        // destroys, or touches a ``` pairing, and an edit that UN-closes a
        // block (trailing chars on its closer line) makes the reparsed block
        // reach the window end — caught by the trailing guard below. Typing
        // inside a code block used to fall back to a full O(doc) reparse on
        // every keystroke because of an unconditional bail here.

        // 4. Window → new-text range (window start is before the edit → unchanged).
        let winStart = oldBlocks[winFirst].range.location
        guard winStart >= 0 else { return nil }

        // 5. Reparse the window, extending it until the trailing block cannot
        // absorb or reinterpret untouched suffix lines. A fixed block margin
        // is insufficient because setext underlines, table separators and
        // continuation lines act on the block before them.
        var winEndNew = 0
        var reparsed: [Block] = []
        while true {
            winEndNew = NSMaxRange(oldBlocks[winLast].range) + delta
            guard winEndNew >= winStart, winEndNew <= newLen else { return nil }
            let windowText = newNS.substring(
                with: NSRange(location: winStart, length: winEndNew - winStart)
            )
            reparsed = computeBlocks(
                windowText,
                registry: registry,
                documentOffset: winStart
            ).map { $0.shifted(by: winStart) }

            guard winLast + 1 < oldBlocks.count,
                  trailingBlockNeedsFollowingText(
                    reparsed,
                    windowEnd: winEndNew,
                    in: newNS,
                    registry: registry
                  )
            else { break }
            winLast += 1
        }
        // A trailing fence or extension block reaching the window end might continue past it.
        if let last = reparsed.last, NSMaxRange(last.range) >= winEndNew {
            switch last.kind {
            case .frontmatter, .fencedCode, .ext:
                if !opaqueBlockClosesWithinRange(last, in: newNS, registry: registry) {
                    return nil
                }
            case .linkDefinition, .footnoteDefinition:
                return nil
            case .paragraph:
                // The edit may have dissolved the separator that used to end
                // this paragraph (backspace-joining two paragraphs): if the
                // suffix ALSO starts with a paragraph, the two would need to
                // MERGE — a full parse never yields adjacent paragraphs. The
                // splice can't merge across the cut, so fall back.
                if winLast + 1 < oldBlocks.count, oldBlocks[winLast + 1].kind == .paragraph {
                    return nil
                }
            default: break
            }
        }

        // 6. Splice: prefix (unchanged) + reparsed window + suffix (shifted).
        var result: [Block] = []
        result.append(contentsOf: oldBlocks[0..<winFirst])
        result.append(contentsOf: reparsed)
        if winLast + 1 < oldBlocks.count {
            result.append(contentsOf: oldBlocks[(winLast + 1)...].map { $0.shifted(by: delta) })
        }

        // 7. Validate gap-free tiling of [0, newLen); else full reparse.
        var cursor = 0
        for b in result {
            if b.range.location != cursor { return nil }
            cursor = NSMaxRange(b.range)
        }
        guard cursor == newLen else { return nil }
        return (result, reparsed.count)
    }

    private static func trailingBlockNeedsFollowingText(
        _ blocks: [Block],
        windowEnd: Int,
        in text: NSString,
        registry: ExtensionRegistry
    ) -> Bool {
        guard let last = blocks.last, NSMaxRange(last.range) >= windowEnd else {
            return false
        }
        switch last.kind {
        case .paragraph, .table, .linkDefinition, .footnoteDefinition, .list, .blockquote:
            return true
        case .frontmatter, .fencedCode, .ext:
            return !opaqueBlockClosesWithinRange(last, in: text, registry: registry)
        case .blank:
            guard blocks.count > 1 else { return false }
            let previous = blocks[blocks.count - 2]
            guard previous.kind == .fencedCode else { return false }
            return !opaqueBlockClosesWithinRange(previous, in: text, registry: registry)
        case .heading, .thematicBreak:
            return false
        }
    }

    private static func opaqueBlockClosesWithinRange(
        _ block: Block,
        in text: NSString,
        registry: ExtensionRegistry
    ) -> Bool {
        let blockEnd = NSMaxRange(block.range)
        guard block.range.location >= 0, block.range.length > 0, blockEnd <= text.length else {
            return false
        }

        let openingLine = NSIntersectionRange(
            text.lineRange(for: NSRange(location: block.range.location, length: 0)),
            block.range
        )
        let closingLine = NSIntersectionRange(
            text.lineRange(for: NSRange(location: blockEnd - 1, length: 0)),
            block.range
        )
        guard closingLine.location > openingLine.location else { return false }

        let openingText = text.substring(with: openingLine)
        let closingText = text.substring(with: closingLine)
        switch block.kind {
        case .frontmatter:
            let close = lineBody(closingText)
            return lineBody(openingText) == "---" && (close == "---" || close == "...")
        case .fencedCode:
            guard let opening = fence(openingText) else { return false }
            return isFenceClose(closingText, opening: opening)
        case .ext(let id):
            guard let fence = registry.blockEntry(for: id)?.fence else { return false }
            return closingText.hasPrefix(fence)
        default:
            return false
        }
    }

    static func computeBlocks(
        _ text: String,
        registry: ExtensionRegistry = .empty,
        documentOffset: Int = 0
    ) -> [Block] {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return [] }

        // 1. Slice into physical lines (each includes its trailing newline).
        var lines: [NSRange] = []
        var cursor = 0
        while cursor < length {
            let r = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            lines.append(r)
            cursor = NSMaxRange(r)
        }

        func lineText(_ i: Int) -> String { nsText.substring(with: lines[i]) }

        /// Line index of the matching fence closing a code block opened at `start`; nil when unclosed.
        func fenceCloseIndex(from start: Int, opening: Fence) -> Int? {
            var scan = start + 1
            while scan < lines.count {
                if isFenceClose(lineText(scan), opening: opening) { return scan }
                scan += 1
            }
            return nil
        }

        func frontmatterCloseIndex() -> Int? {
            guard documentOffset == 0, lineBody(lineText(0)) == "---" else { return nil }
            for scan in 1..<lines.count {
                let body = lineBody(lineText(scan))
                if body == "---" || body == "..." { return scan }
            }
            return nil
        }

        func isLinkDefinitionLine(_ index: Int) -> Bool {
            MarkdownLinkSyntax.linkDefinition(in: nsText, lineRange: lines[index]) != nil
        }

        func isFootnoteDefinitionLine(_ index: Int) -> Bool {
            MarkdownLinkSyntax.footnoteDefinitionHeader(in: nsText, lineRange: lines[index]) != nil
        }

        // 2. Classify + group.
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lineText(i)

            if i == 0, let end = frontmatterCloseIndex() {
                blocks.append(Block(kind: .frontmatter, range: union(lines[i...end])))
                i = end + 1

            } else if isFootnoteDefinitionLine(i) {
                var end = i
                while end + 1 < lines.count, isIndentedCodeLine(lineText(end + 1)) {
                    end += 1
                }
                blocks.append(Block(kind: .footnoteDefinition, range: union(lines[i...end])))
                i = end + 1

            } else if isLinkDefinitionLine(i) {
                var end = i
                while end + 1 < lines.count, isLinkDefinitionLine(end + 1) { end += 1 }
                blocks.append(Block(kind: .linkDefinition, range: union(lines[i...end])))
                i = end + 1

            } else if isBlank(line) {
                var end = i
                while end + 1 < lines.count, isBlank(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .blank, range: union(lines[i...end])))
                i = end + 1

            } else if let opening = fence(line), let end = fenceCloseIndex(from: i, opening: opening) {
                blocks.append(Block(kind: .fencedCode, range: union(lines[i...end])))
                i = end + 1

            } else if isThematicBreak(line) {
                blocks.append(Block(kind: .thematicBreak, range: lines[i]))
                i += 1

            } else if isIndentedCodeLine(line) && !isListItem(line) {
                var scan = i
                var end = i
                while scan + 1 < lines.count {
                    let next = lineText(scan + 1)
                    if isBlank(next) {
                        scan += 1
                    } else if isIndentedCodeLine(next) {
                        scan += 1
                        end = scan
                    } else {
                        break
                    }
                }
                blocks.append(Block(kind: .fencedCode, range: union(lines[i...end])))
                i = end + 1

            } else if isHeading(line) {
                blocks.append(Block(kind: .heading, range: lines[i]))
                i += 1

            } else if isBlockquote(line) {
                var end = i
                while end + 1 < lines.count, isBlockquote(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .blockquote, range: union(lines[i...end])))
                i = end + 1

            } else if isListItem(line) {
                // Four-column continuation lines belong to the preceding item;
                // classifying them as code would split a list in the middle.
                var end = i
                while end + 1 < lines.count {
                    let next = lineText(end + 1)
                    guard isListItem(next) || isIndentedCodeLine(next) else { break }
                    end += 1
                }
                blocks.append(Block(kind: .list, range: union(lines[i...end])))
                i = end + 1

            } else if isTableRow(line), i + 1 < lines.count, isTableSeparator(lineText(i + 1)) {
                // GFM table: a `|…|` header, a `|-…-|` separator, then data rows.
                var end = i + 1
                while end + 1 < lines.count, isTableRow(lineText(end + 1)) { end += 1 }
                blocks.append(Block(kind: .table, range: union(lines[i...end])))
                i = end + 1

            } else if let entry = registry.blockEntry(opening: line) {
                // Extension fenced block: consume through the closing fence
                // line (or to EOF if none) — mirrors ``` semantics. Built-ins
                // classify first, so a fence colliding with a built-in line
                // form never reaches here.
                var end = lines.count - 1
                var scan = i + 1
                while scan < lines.count {
                    if lineText(scan).hasPrefix(entry.fence) { end = scan; break }
                    scan += 1
                }
                blocks.append(Block(kind: .ext(entry.id), range: union(lines[i...end])))
                i = end + 1

            } else {
                // Paragraph: merge consecutive plain (non-blank, non-special) lines.
                var end = i
                var setextEnd: Int?
                while end + 1 < lines.count {
                    let next = lineText(end + 1)
                    if setextLevel(next) != nil {
                        setextEnd = end + 1
                        break
                    }
                    // Indented code cannot interrupt paragraph text. This check
                    // must precede list/heading recognition on the indented line.
                    if isIndentedCodeLine(next) {
                        end += 1
                        continue
                    }
                    if isBlank(next) || isThematicBreak(next)
                        || isHeading(next) || isBlockquote(next) || isListItem(next)
                        || isLinkDefinitionLine(end + 1) || isFootnoteDefinitionLine(end + 1) { break }
                    // A table (row + separator), a CLOSED code fence, or an
                    // extension fence interrupts it —
                    // an unclosed opener stays part of the paragraph.
                    if let opening = fence(next),
                       fenceCloseIndex(from: end + 1, opening: opening) != nil { break }
                    if isTableRow(next), end + 2 < lines.count, isTableSeparator(lineText(end + 2)) { break }
                    if registry.blockEntry(opening: next) != nil { break }
                    end += 1
                }
                if let setextEnd {
                    blocks.append(Block(kind: .heading, range: union(lines[i...setextEnd])))
                    i = setextEnd + 1
                } else {
                    blocks.append(Block(kind: .paragraph, range: union(lines[i...end])))
                    i = end + 1
                }
            }
        }
        return blocks
    }

    // MARK: - Line classification

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private struct Fence {
        let character: Character
        let count: Int
    }

    /// Column-zero matching preserves the engine's existing fence indentation contract.
    private static func fence(_ line: String) -> Fence? {
        let body = lineBody(line)
        guard let character = body.first, character == "`" || character == "~" else { return nil }
        let count = body.prefix { $0 == character }.count
        guard count >= 3 else { return nil }
        return Fence(character: character, count: count)
    }

    private static func isFenceClose(_ line: String, opening: Fence) -> Bool {
        let body = lineBody(line)
        let run = body.prefix { $0 == opening.character }
        guard run.count >= opening.count else { return false }
        return body.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first,
              first == "-" || first == "*" || first == "_" else { return false }
        let markers = t.filter { $0 != " " && $0 != "\t" }
        return markers.count >= 3 && markers.allSatisfy { $0 == first }
    }

    private static func setextLevel(_ line: String) -> Int? {
        let body = lineBody(line)
        let indent = body.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = body.dropFirst(indent)
        guard let marker = rest.first, marker == "=" || marker == "-" else { return nil }
        let run = rest.prefix { $0 == marker }
        guard !run.isEmpty,
              rest.dropFirst(run.count).allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        return marker == "=" ? 1 : 2
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        indentationColumns(line) >= 4
    }

    private static func indentationColumns(_ line: String) -> Int {
        var column = 0
        for character in line {
            if character == " " {
                column += 1
            } else if character == "\t" {
                column += 4 - column % 4
            } else {
                break
            }
        }
        return column
    }

    private static func lineBody(_ line: String) -> Substring {
        line.dropLast(line.reversed().prefix { $0.isNewline }.count)
    }

    private static func isFrontmatterDelimiter(_ buf: [unichar], from start: Int, to end: Int) -> Bool {
        guard end - start == 3 else { return false }
        let first = buf[start]
        guard first == 0x2D || first == 0x2E else { return false }
        return buf[start + 1] == first && buf[start + 2] == first
    }

    /// `^\s*#{1,6} +…` — 1–6 hashes after optional indent, then at least one space.
    private static func isHeading(_ line: String) -> Bool {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        var hashes = 0
        while let c = rest.first, c == "#" { hashes += 1; rest = rest.dropFirst() }
        guard (1...6).contains(hashes) else { return false }
        return rest.first == " "
    }

    /// `^[ \t]{0,3}>…` — up to 3 leading spaces/tabs, then a `>`.
    private static func isBlockquote(_ line: String) -> Bool {
        var rest = Substring(line)
        var indent = 0
        while indent < 3, let c = rest.first, c == " " || c == "\t" {
            rest = rest.dropFirst(); indent += 1
        }
        return rest.first == ">"
    }

    /// A list-item line: optional indent, a bullet (`-`/`*`/`+`) or ordered marker (`1.`/`1)`), then a space/tab.
    static func isListItem(_ line: String) -> Bool {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            rest = rest.dropFirst()
        } else if first.isNumber {
            var digits = 0
            while let c = rest.first, c.isNumber, digits < 9 { rest = rest.dropFirst(); digits += 1 }
            guard let d = rest.first, d == "." || d == ")" else { return false }
            rest = rest.dropFirst()
        } else {
            return false
        }
        // A space/tab must follow the marker — a bare `-`/`*`/`1.` stays literal (pre-AST bullet behavior).
        guard let after = rest.first else { return false }
        return after == " " || after == "\t"
    }

    /// A GFM table row: `^[ \t]*\|.+\|[ \t]*$` — outer pipes, content between.
    private static func isTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 3 && t.hasPrefix("|") && t.hasSuffix("|")
    }

    /// A GFM table separator: `^[ \t]*\|[- \t:|]+\|[ \t]*$` — only `- : |` + ws inside.
    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, t.hasPrefix("|"), t.hasSuffix("|") else { return false }
        let middle = t.dropFirst().dropLast()
        return !middle.isEmpty && middle.allSatisfy {
            $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " || $0 == "\t"
        }
    }

    private static func union(_ ranges: ArraySlice<NSRange>) -> NSRange {
        let lo = ranges.first!.location
        let hi = NSMaxRange(ranges.last!)
        return NSRange(location: lo, length: hi - lo)
    }
}

private extension Block {
    /// A copy with the range moved by `d` UTF-16 units.
    func shifted(by d: Int) -> Block {
        Block(kind: kind, range: NSRange(location: range.location + d, length: range.length))
    }
}

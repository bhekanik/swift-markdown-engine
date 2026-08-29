import Foundation

struct ParsedLinkTarget: Equatable {
    let destination: NSRange
    let title: NSRange?
    let markers: [NSRange]
}

struct ParsedLinkDefinition: Equatable {
    let lineRange: NSRange
    let label: NSRange
    let destination: NSRange
    let title: NSRange?
}

struct ParsedFootnoteDefinitionHeader: Equatable {
    let label: NSRange
    let markers: [NSRange]
    let bodyStart: Int
}

enum MarkdownLinkSyntax {
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09
    private static let lf: unichar = 0x0A
    private static let cr: unichar = 0x0D
    private static let backslash: unichar = 0x5C
    private static let lbracket: unichar = 0x5B
    private static let rbracket: unichar = 0x5D
    private static let lparen: unichar = 0x28
    private static let rparen: unichar = 0x29
    private static let langle: unichar = 0x3C
    private static let rangle: unichar = 0x3E
    private static let doubleQuote: unichar = 0x22
    private static let singleQuote: unichar = 0x27
    private static let colon: unichar = 0x3A
    private static let caret: unichar = 0x5E

    static func inlineTarget(
        in ns: NSString,
        from start: Int,
        length: Int
    ) -> (closeParen: Int, target: ParsedLinkTarget)? {
        var i = start
        skipWhitespace(in: ns, index: &i, end: length)

        if i < length, ns.character(at: i) == rparen {
            return (i, ParsedLinkTarget(
                destination: NSRange(location: i, length: 0),
                title: nil,
                markers: []
            ))
        }

        let destination: NSRange
        var markers: [NSRange] = []
        if i < length, ns.character(at: i) == langle {
            let open = i
            i += 1
            let destinationStart = i
            guard let close = closingAngleDestination(in: ns, from: i, end: length) else {
                return nil
            }
            i = close
            destination = NSRange(location: destinationStart, length: i - destinationStart)
            markers = [NSRange(location: open, length: 1), NSRange(location: i, length: 1)]
            i += 1
        } else {
            let destinationStart = i
            var depth = 0
            while i < length {
                let c = ns.character(at: i)
                guard c != lf, c != cr else { return nil }
                if isWhitespace(c) { break }
                if c == backslash, i + 1 < length {
                    i += 2
                    continue
                }
                if c == lparen {
                    depth += 1
                } else if c == rparen {
                    if depth == 0 {
                        return (i, ParsedLinkTarget(
                            destination: NSRange(location: destinationStart, length: i - destinationStart),
                            title: nil,
                            markers: []
                        ))
                    }
                    depth -= 1
                }
                i += 1
            }
            guard depth == 0 else { return nil }
            destination = NSRange(location: destinationStart, length: i - destinationStart)
        }

        let separatorStart = i
        skipWhitespace(in: ns, index: &i, end: length)
        guard i < length else { return nil }
        if ns.character(at: i) == rparen {
            return (i, ParsedLinkTarget(destination: destination, title: nil, markers: markers))
        }
        guard i > separatorStart,
              let parsedTitle = title(in: ns, from: i, end: length) else { return nil }
        i = parsedTitle.end
        skipWhitespace(in: ns, index: &i, end: length)
        guard i < length, ns.character(at: i) == rparen else { return nil }
        markers.append(contentsOf: parsedTitle.markers)
        return (i, ParsedLinkTarget(
            destination: destination,
            title: parsedTitle.content,
            markers: markers
        ))
    }

    static func linkDefinition(in ns: NSString, lineRange: NSRange) -> ParsedLinkDefinition? {
        let end = contentEnd(of: lineRange, in: ns)
        var i = lineRange.location
        var indent = 0
        while i < end, ns.character(at: i) == space, indent < 4 {
            i += 1
            indent += 1
        }
        guard indent <= 3,
              i < end, ns.character(at: i) == lbracket,
              i + 1 < end, ns.character(at: i + 1) != caret,
              let close = closingBracket(in: ns, from: i + 1, end: end),
              close + 1 < end, ns.character(at: close + 1) == colon else { return nil }

        let label = NSRange(location: i + 1, length: close - i - 1)
        guard !normalizedLabel(in: ns, range: label).isEmpty else { return nil }
        i = close + 2
        skipWhitespace(in: ns, index: &i, end: end)
        guard let target = definitionTarget(in: ns, from: i, end: end) else { return nil }
        return ParsedLinkDefinition(
            lineRange: lineRange,
            label: label,
            destination: target.destination,
            title: target.title
        )
    }

    static func footnoteDefinitionHeader(
        in ns: NSString,
        lineRange: NSRange
    ) -> ParsedFootnoteDefinitionHeader? {
        let end = contentEnd(of: lineRange, in: ns)
        var i = lineRange.location
        var indent = 0
        while i < end, ns.character(at: i) == space, indent < 4 {
            i += 1
            indent += 1
        }
        let opener = i
        guard indent <= 3,
              i + 2 < end,
              ns.character(at: i) == lbracket,
              ns.character(at: i + 1) == caret,
              let close = closingBracket(in: ns, from: i + 2, end: end),
              close + 1 < end, ns.character(at: close + 1) == colon else { return nil }
        let label = NSRange(location: i + 2, length: close - i - 2)
        guard !normalizedLabel(in: ns, range: label).isEmpty else { return nil }

        i = close + 2
        skipWhitespace(in: ns, index: &i, end: end)
        return ParsedFootnoteDefinitionHeader(
            label: label,
            markers: [
                NSRange(location: lineRange.location, length: opener + 2 - lineRange.location),
                NSRange(location: close, length: i - close),
            ],
            bodyStart: i
        )
    }

    static func normalizedLabel(in ns: NSString, range: NSRange) -> String {
        normalizedLabel(ns.substring(with: range))
    }

    static func normalizedLabel(_ label: String) -> String {
        label
            .folding(options: [.caseInsensitive], locale: nil)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    static func contentEnd(of lineRange: NSRange, in ns: NSString) -> Int {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let c = ns.character(at: end - 1)
            guard c == lf || c == cr else { break }
            end -= 1
        }
        return end
    }

    private static func definitionTarget(in ns: NSString, from start: Int, end: Int) -> ParsedLinkTarget? {
        guard start < end else { return nil }
        var i = start
        let destination: NSRange
        var markers: [NSRange] = []
        if ns.character(at: i) == langle {
            let open = i
            i += 1
            let destinationStart = i
            guard let close = closingAngleDestination(in: ns, from: i, end: end) else {
                return nil
            }
            i = close
            destination = NSRange(location: destinationStart, length: i - destinationStart)
            markers = [NSRange(location: open, length: 1), NSRange(location: i, length: 1)]
            i += 1
        } else {
            let destinationStart = i
            var depth = 0
            while i < end, !isWhitespace(ns.character(at: i)) {
                let c = ns.character(at: i)
                if c == backslash, i + 1 < end {
                    i += 2
                    continue
                }
                if c == lparen { depth += 1 }
                if c == rparen {
                    guard depth > 0 else { return nil }
                    depth -= 1
                }
                i += 1
            }
            guard i > destinationStart, depth == 0 else { return nil }
            destination = NSRange(location: destinationStart, length: i - destinationStart)
        }

        let separatorStart = i
        skipWhitespace(in: ns, index: &i, end: end)
        if i == end {
            return ParsedLinkTarget(destination: destination, title: nil, markers: markers)
        }
        guard i > separatorStart,
              let parsedTitle = title(in: ns, from: i, end: end) else { return nil }
        i = parsedTitle.end
        skipWhitespace(in: ns, index: &i, end: end)
        guard i == end else { return nil }
        markers.append(contentsOf: parsedTitle.markers)
        return ParsedLinkTarget(destination: destination, title: parsedTitle.content, markers: markers)
    }

    private static func title(
        in ns: NSString,
        from start: Int,
        end: Int
    ) -> (content: NSRange, markers: [NSRange], end: Int)? {
        guard start < end else { return nil }
        let opener = ns.character(at: start)
        let closer: unichar
        switch opener {
        case doubleQuote: closer = doubleQuote
        case singleQuote: closer = singleQuote
        case lparen: closer = rparen
        default: return nil
        }
        var i = start + 1
        while i < end {
            if ns.character(at: i) == backslash, i + 1 < end {
                i += 2
                continue
            }
            if ns.character(at: i) == closer {
                return (
                    NSRange(location: start + 1, length: i - start - 1),
                    [NSRange(location: start, length: 1), NSRange(location: i, length: 1)],
                    i + 1
                )
            }
            i += 1
        }
        return nil
    }

    private static func closingBracket(in ns: NSString, from start: Int, end: Int) -> Int? {
        var i = start
        while i < end {
            if ns.character(at: i) == rbracket, !isEscaped(i, in: ns) { return i }
            i += 1
        }
        return nil
    }

    private static func closingAngleDestination(
        in ns: NSString,
        from start: Int,
        end: Int
    ) -> Int? {
        var i = start
        while i < end {
            let character = ns.character(at: i)
            if character == lf || character == cr { return nil }
            if character == langle, !isEscaped(i, in: ns) { return nil }
            if character == rangle, !isEscaped(i, in: ns) { return i }
            i += 1
        }
        return nil
    }

    static func unescapedText(in ns: NSString, range: NSRange) -> String {
        var codeUnits: [unichar] = []
        codeUnits.reserveCapacity(range.length)
        var i = range.location
        let end = NSMaxRange(range)
        while i < end {
            let character = ns.character(at: i)
            if character == backslash, i + 1 < end {
                let next = ns.character(at: i + 1)
                if isAsciiPunctuation(next) {
                    codeUnits.append(next)
                    i += 2
                    continue
                }
            }
            codeUnits.append(character)
            i += 1
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    static func escapeMarkerRanges(in ns: NSString, range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var i = range.location
        let end = NSMaxRange(range)
        while i + 1 < end {
            if ns.character(at: i) == backslash,
               isAsciiPunctuation(ns.character(at: i + 1)) {
                result.append(NSRange(location: i, length: 1))
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }

    private static func skipWhitespace(in ns: NSString, index: inout Int, end: Int) {
        while index < end, isWhitespace(ns.character(at: index)) { index += 1 }
    }

    private static func isWhitespace(_ c: unichar) -> Bool {
        c == space || c == tab
    }

    private static func isAsciiPunctuation(_ character: unichar) -> Bool {
        (character >= 0x21 && character <= 0x2F)
            || (character >= 0x3A && character <= 0x40)
            || (character >= 0x5B && character <= 0x60)
            || (character >= 0x7B && character <= 0x7E)
    }

    private static func isEscaped(_ index: Int, in ns: NSString) -> Bool {
        var count = 0
        var i = index - 1
        while i >= 0, ns.character(at: i) == backslash {
            count += 1
            i -= 1
        }
        return count % 2 == 1
    }
}

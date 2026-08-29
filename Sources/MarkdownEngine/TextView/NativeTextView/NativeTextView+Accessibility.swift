//
//  NativeTextView+Accessibility.swift
//  MarkdownEngine
//

import AppKit

extension NativeTextView {
    private var markdownAccessibility: MarkdownAccessibilityProjection {
        let coordinator = delegate as? NativeTextViewCoordinator
        let generation = coordinator?.parseGeneration ?? 0
        let accessibilityConfiguration = coordinator?.configuration ?? configuration
        let registryFingerprint = accessibilityConfiguration.extensionRegistry.fingerprint
        if let cached = accessibilityProjectionCache,
           accessibilityProjectionGeneration == generation,
           accessibilityProjectionRawSourceMode == accessibilityConfiguration.rawSourceMode,
           accessibilityProjectionRegistryFingerprint == registryFingerprint {
            return cached
        }

        let projection = MarkdownAccessibilityProjection.make(
            markdown: string,
            configuration: accessibilityConfiguration
        )
        accessibilityProjectionCache = projection
        accessibilityProjectionGeneration = generation
        accessibilityProjectionRawSourceMode = accessibilityConfiguration.rawSourceMode
        accessibilityProjectionRegistryFingerprint = registryFingerprint
        return projection
    }

    override func accessibilityNumberOfCharacters() -> Int {
        markdownAccessibility.text.visibleUTF16Length
    }

    override func accessibilityValue() -> String? {
        markdownAccessibility.text.string
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let visible = markdownAccessibility.text.string
        guard Self.isValidAccessibilityRange(range, length: (visible as NSString).length),
              let swiftRange = Range(range, in: visible) else { return nil }
        return String(visible[swiftRange])
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let substring = accessibilityString(for: range) else { return nil }
        let result = NSMutableAttributedString(string: substring)

        for span in markdownAccessibility.spans {
            let intersection = NSIntersectionRange(span.visibleRange, range)
            guard intersection.length > 0 else { continue }
            let localRange = NSRange(
                location: intersection.location - range.location,
                length: intersection.length
            )
            switch span.role {
            case .heading(let level):
                result.addAttribute(
                    .accessibilityCustomText,
                    value: ["Heading level \(level)"],
                    range: localRange
                )

            case .listItem(let level, let index, let prefix, _):
                result.addAttributes([
                    .accessibilityListItemPrefix: NSAttributedString(string: prefix),
                    .accessibilityListItemIndex: index,
                    .accessibilityListItemLevel: level,
                ], range: localRange)

            case .link:
                result.addAttribute(.accessibilityLink, value: self, range: localRange)

            case .image(let label, _):
                result.addAttributes([
                    .accessibilityAttachment: self,
                    .accessibilityCustomText: ["Image: \(label)"],
                ], range: localRange)

            case .footnoteReference(let label):
                result.addAttribute(
                    .accessibilityCustomText,
                    value: ["Footnote reference: \(label)"],
                    range: localRange
                )

            case .footnoteDefinition(let label):
                result.addAttribute(
                    .accessibilityCustomText,
                    value: ["Footnote: \(label)"],
                    range: localRange
                )
            }
        }
        return result
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        markdownAccessibility.text.visibleRange(for: selectedRange())
            ?? NSRange(location: 0, length: 0)
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard let sourceRange = markdownAccessibility.text.sourceRange(for: range) else { return }
        setSelectedRange(sourceRange)
    }

    override func accessibilitySelectedText() -> String? {
        accessibilityString(for: accessibilitySelectedTextRange())
    }

    override func accessibilitySelectedTextRanges() -> [NSValue]? {
        selectedRanges.compactMap {
            markdownAccessibility.text.visibleRange(for: $0.rangeValue).map(NSValue.init(range:))
        }
    }

    override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
        guard let ranges else { return }
        let sourceRanges = ranges.compactMap {
            markdownAccessibility.text.sourceRange(for: $0.rangeValue).map(NSValue.init(range:))
        }
        guard sourceRanges.count == ranges.count else { return }
        selectedRanges = sourceRanges
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        accessibilityLine(for: accessibilitySelectedTextRange().location)
    }

    override func accessibilityRTF(for range: NSRange) -> Data? {
        accessibilityAttributedString(for: range)?.rtf(
            from: NSRange(location: 0, length: range.length),
            documentAttributes: [:]
        )
    }

    override func accessibilityStyleRange(for index: Int) -> NSRange {
        guard index >= 0, index < markdownAccessibility.text.visibleUTF16Length,
              let sourceBoundary = markdownAccessibility.text.sourceRange(
                for: NSRange(location: index, length: 0)
              ) else { return NSRange(location: NSNotFound, length: 0) }
        let sourceRange = super.accessibilityStyleRange(for: sourceBoundary.location)
        return markdownAccessibility.text.visibleRange(for: sourceRange)
            ?? NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        guard let textLayoutManager,
              let viewport = textLayoutManager.textViewportLayoutController.viewportRange
        else { return NSRange(location: 0, length: 0) }
        let sourceStart = textLayoutManager.offset(
            from: textLayoutManager.documentRange.location,
            to: viewport.location
        )
        let sourceLength = textLayoutManager.offset(
            from: viewport.location,
            to: viewport.endLocation
        )
        return markdownAccessibility.text.visibleRange(
            for: NSRange(location: sourceStart, length: sourceLength)
        ) ?? NSRange(location: 0, length: 0)
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard line >= 0 else { return NSRange(location: NSNotFound, length: 0) }
        let text = markdownAccessibility.text.string as NSString
        var cursor = 0
        var currentLine = 0
        while cursor < text.length {
            let range = text.lineRange(for: NSRange(location: cursor, length: 0))
            if currentLine == line { return range }
            cursor = NSMaxRange(range)
            currentLine += 1
        }
        if currentLine == line, cursor == text.length {
            return NSRange(location: cursor, length: 0)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilityLine(for index: Int) -> Int {
        let text = markdownAccessibility.text.string as NSString
        guard index >= 0, index <= text.length else { return NSNotFound }
        var line = 0
        var cursor = 0
        while cursor < index {
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(
                nil,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            guard lineEnd > cursor,
                  index > lineEnd || (index == lineEnd && contentsEnd < lineEnd)
            else { break }
            line += 1
            cursor = lineEnd
        }
        return line
    }

    override func accessibilityRange(for index: Int) -> NSRange {
        let text = markdownAccessibility.text.string as NSString
        guard index >= 0, index < text.length else {
            return index == text.length
                ? NSRange(location: index, length: 0)
                : NSRange(location: NSNotFound, length: 0)
        }
        return text.rangeOfComposedCharacterSequence(at: index)
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let sourceRange = markdownAccessibility.text.sourceRange(for: range),
              let localRect = accessibilityLocalRect(forSourceRange: sourceRange),
              let window else { return .zero }
        return window.convertToScreen(convert(localRect, to: nil))
    }

    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let window,
              let layoutBridge,
              let textContainer else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let source = string as NSString
        let windowPoint = window.convertFromScreen(NSRect(origin: point, size: .zero)).origin
        let viewPoint = convert(windowPoint, from: nil)
        let containerPoint = CGPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        var fraction: CGFloat = 0
        let index = layoutBridge.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard index != NSNotFound, index < source.length else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let sourceRange = source.rangeOfComposedCharacterSequence(at: index)
        return markdownAccessibility.text.visibleRange(for: sourceRange)
            ?? NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        let spans = markdownAccessibility.spans
        var rotors = super.accessibilityCustomRotors()
        let roles = Set(spans.map(\.rotorCategory))

        if roles.contains(.heading) {
            rotors.append(NSAccessibilityCustomRotor(
                rotorType: .heading,
                itemSearchDelegate: self
            ))
        }
        for level in 1...6 where spans.contains(where: { $0.headingLevel == level }) {
            rotors.append(NSAccessibilityCustomRotor(
                rotorType: Self.headingRotorType(level),
                itemSearchDelegate: self
            ))
        }
        if roles.contains(.list) {
            rotors.append(NSAccessibilityCustomRotor(
                rotorType: .list,
                itemSearchDelegate: self
            ))
        }
        if roles.contains(.link) {
            rotors.append(NSAccessibilityCustomRotor(
                rotorType: .link,
                itemSearchDelegate: self
            ))
        }
        if roles.contains(.image) {
            rotors.append(NSAccessibilityCustomRotor(
                rotorType: .image,
                itemSearchDelegate: self
            ))
        }
        if roles.contains(.footnote) {
            rotors.append(NSAccessibilityCustomRotor(
                label: "Footnotes",
                itemSearchDelegate: self
            ))
        }
        return rotors
    }

    private func accessibilityLocalRect(forSourceRange range: NSRange) -> CGRect? {
        let sourceLength = (string as NSString).length
        guard Self.isValidAccessibilityRange(range, length: sourceLength),
              let textLayoutManager,
              let contentManager = textLayoutManager.textContentManager,
              let start = contentManager.location(
                contentManager.documentRange.location,
                offsetBy: range.location
              ) else { return nil }
        if range.length == 0 {
            return accessibilityCaretRect(
                at: start,
                sourceOffset: range.location,
                textLayoutManager: textLayoutManager,
                contentManager: contentManager
            )
        }
        guard
              let end = contentManager.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        textLayoutManager.ensureLayout(for: textRange)
        var result = CGRect.null
        textLayoutManager.enumerateTextSegments(
            in: textRange,
            type: .selection,
            options: []
        ) { _, rect, _, _ in
            let local = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            result = result.isNull ? local : result.union(local)
            return true
        }
        return result.isNull ? nil : result
    }

    private func accessibilityCaretRect(
        at location: NSTextLocation,
        sourceOffset: Int,
        textLayoutManager: NSTextLayoutManager,
        contentManager: NSTextContentManager
    ) -> CGRect? {
        let caretRange = NSTextRange(location: location)
        textLayoutManager.ensureLayout(for: caretRange)
        var result: CGRect?
        textLayoutManager.enumerateTextSegments(
            in: caretRange,
            type: .standard,
            options: []
        ) { _, rect, _, _ in
            result = CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
                .offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            return false
        }
        if let result, result.height > 0 { return result }

        guard sourceOffset > 0,
              let previous = contentManager.location(location, offsetBy: -1),
              let previousRange = NSTextRange(location: previous, end: location)
        else { return nil }
        textLayoutManager.ensureLayout(for: previousRange)
        textLayoutManager.enumerateTextSegments(
            in: previousRange,
            type: .selection,
            options: []
        ) { _, rect, _, _ in
            let precedingCharacter = (self.string as NSString).character(at: sourceOffset - 1)
            let startsNextLine = precedingCharacter == 0x0A || precedingCharacter == 0x0D
            result = CGRect(
                x: startsNextLine ? 0 : rect.maxX,
                y: startsNextLine ? rect.maxY : rect.minY,
                width: 0,
                height: rect.height
            )
                .offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            return false
        }
        return result
    }

    private static func isValidAccessibilityRange(_ range: NSRange, length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }

    private static func headingRotorType(_ level: Int) -> NSAccessibilityCustomRotor.RotorType {
        switch level {
        case 1: .headingLevel1
        case 2: .headingLevel2
        case 3: .headingLevel3
        case 4: .headingLevel4
        case 5: .headingLevel5
        default: .headingLevel6
        }
    }
}

extension NativeTextView: NSAccessibilityCustomRotorItemSearchDelegate {
    func rotor(
        _ rotor: NSAccessibilityCustomRotor,
        resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        let projection = markdownAccessibility
        let candidates = projection.spans.filter {
            $0.matches(rotor: rotor) && $0.matches(filter: searchParameters.filterString,
                                                   visibleText: projection.text.string)
        }
        guard let span = candidates.next(
            after: searchParameters.currentItem?.targetRange,
            direction: searchParameters.searchDirection
        ) else { return nil }

        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = span.visibleRange
        result.customLabel = span.accessibilityLabel(in: projection.text.string)
        return result
    }
}

private enum AccessibilityRotorCategory: Hashable {
    case heading
    case list
    case link
    case image
    case footnote
}

private extension MarkdownAccessibilitySpan {
    var rotorCategory: AccessibilityRotorCategory {
        switch role {
        case .heading: .heading
        case .listItem: .list
        case .link: .link
        case .image: .image
        case .footnoteReference, .footnoteDefinition: .footnote
        }
    }

    var headingLevel: Int? {
        guard case .heading(let level) = role else { return nil }
        return level
    }

    func matches(rotor: NSAccessibilityCustomRotor) -> Bool {
        switch rotor.type {
        case .heading:
            return rotorCategory == .heading
        case .headingLevel1:
            return headingLevel == 1
        case .headingLevel2:
            return headingLevel == 2
        case .headingLevel3:
            return headingLevel == 3
        case .headingLevel4:
            return headingLevel == 4
        case .headingLevel5:
            return headingLevel == 5
        case .headingLevel6:
            return headingLevel == 6
        case .list:
            return rotorCategory == .list
        case .link:
            return rotorCategory == .link
        case .image:
            return rotorCategory == .image
        case .custom:
            return rotorCategory == .footnote && rotor.label == "Footnotes"
        default:
            return false
        }
    }

    func matches(filter: String, visibleText: String) -> Bool {
        filter.isEmpty
            || accessibilityLabel(in: visibleText).localizedCaseInsensitiveContains(filter)
    }

    func accessibilityLabel(in visibleText: String) -> String {
        let content = (visibleText as NSString)
            .substring(with: visibleRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch role {
        case .heading, .listItem, .link:
            return content
        case .image(let label, _):
            return label.isEmpty ? "Image" : label
        case .footnoteReference(let label):
            return "Footnote reference \(label)"
        case .footnoteDefinition(let label):
            return "Footnote \(label): \(content)"
        }
    }
}

private extension Array where Element == MarkdownAccessibilitySpan {
    func next(
        after currentRange: NSRange?,
        direction: NSAccessibilityCustomRotor.SearchDirection
    ) -> MarkdownAccessibilitySpan? {
        guard !isEmpty else { return nil }
        guard let currentRange else {
            return direction == .next ? first : last
        }
        if let currentIndex = firstIndex(where: { $0.visibleRange == currentRange }) {
            let index = direction == .next ? currentIndex + 1 : currentIndex - 1
            return indices.contains(index) ? self[index] : nil
        }
        switch direction {
        case .next:
            return first { $0.visibleRange.location >= NSMaxRange(currentRange) }
        case .previous:
            return last { NSMaxRange($0.visibleRange) <= currentRange.location }
        @unknown default:
            return nil
        }
    }
}

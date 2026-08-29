//
//  AccessibilityTests.swift
//  MarkdownEngineTests
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Visible Markdown accessibility", .serialized)
struct AccessibilityTests {
    private func view(
        text: String,
        configuration: MarkdownEditorConfiguration = .default
    ) -> NativeTextView {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.textContainer = container
        controller.textContentStorage.addTextLayoutManager(layoutManager)
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            textContainer: container
        )
        textView.isEditable = true
        let coordinator = NativeTextViewWrapper(
            text: .constant(text),
            configuration: configuration,
            controller: controller,
            fontName: "Helvetica",
            fontSize: 16
        ).makeCoordinator()
        coordinator.adopt(textView, text: text)
        return textView
    }

    @Test("visible text and selection hide Markdown syntax")
    func visibleTextAndSelection() throws {
        let source = "# Alpha [bravo](https://secret.example) 👩🏽‍💻\n"
        let textView = view(text: source)
        let visible = "Alpha bravo 👩🏽‍💻\n"

        #expect(textView.accessibilityNumberOfCharacters() == (visible as NSString).length)
        #expect(textView.accessibilityString(
            for: NSRange(location: 0, length: (visible as NSString).length)
        ) == visible)
        #expect(textView.accessibilityString(
            for: NSRange(location: 0, length: Int.max)
        ) == nil)

        let sourceBravo = (source as NSString).range(of: "bravo")
        let visibleBravo = (visible as NSString).range(of: "bravo")
        textView.setSelectedRange(sourceBravo)
        #expect(textView.accessibilitySelectedTextRange() == visibleBravo)
        #expect(textView.accessibilitySelectedText() == "bravo")

        let visibleAlpha = (visible as NSString).range(of: "Alpha")
        textView.setAccessibilitySelectedTextRange(visibleAlpha)
        #expect(textView.selectedRange() == (source as NSString).range(of: "Alpha"))

        let emoji = (visible as NSString).range(of: "👩🏽‍💻")
        #expect(textView.accessibilityRange(for: emoji.location) == emoji)
    }

    @Test("attributed text carries heading, list, link, image and footnote semantics")
    func attributedStructure() throws {
        let source = """
        ## Heading [link](https://example.com)
        - task
        ![Alt](image.png)
        Note[^n].

        [^n]: Footnote body
        """
        let textView = view(text: source)
        let length = textView.accessibilityNumberOfCharacters()
        let attributed = try #require(textView.accessibilityAttributedString(
            for: NSRange(location: 0, length: length)
        ))
        let visible = attributed.string as NSString

        let heading = visible.range(of: "Heading")
        #expect(attributed.attribute(
            .accessibilityCustomText,
            at: heading.location,
            effectiveRange: nil
        ) as? [String] == ["Heading level 2"])

        let task = visible.range(of: "task")
        #expect((attributed.attribute(
            .accessibilityListItemPrefix,
            at: task.location,
            effectiveRange: nil
        ) as? NSAttributedString)?.string == "•")
        #expect(attributed.attribute(
            .accessibilityListItemLevel,
            at: task.location,
            effectiveRange: nil
        ) as? Int == 0)

        let link = visible.range(of: "link")
        #expect(attributed.attribute(
            .accessibilityLink,
            at: link.location,
            effectiveRange: nil
        ) != nil)

        let image = visible.range(of: "Alt")
        #expect(attributed.attribute(
            .accessibilityAttachment,
            at: image.location,
            effectiveRange: nil
        ) != nil)

        let footnote = visible.range(of: "Footnote body")
        #expect(attributed.attribute(
            .accessibilityCustomText,
            at: footnote.location,
            effectiveRange: nil
        ) as? [String] == ["Footnote: n"])
    }

    @Test("standard rotors navigate rendered structure")
    func rotorsNavigateVisibleRanges() throws {
        let source = "# First\n## Second [link](https://example.com) ![Alt](image.png)\n"
        let textView = view(text: source)
        let rotors = textView.accessibilityCustomRotors()
        let headingRotor = try #require(rotors.first { $0.type == .heading })
        let linkRotor = try #require(rotors.first { $0.type == .link })
        let imageRotor = try #require(rotors.first { $0.type == .image })

        let next = NSAccessibilityCustomRotor.SearchParameters()
        next.searchDirection = .next
        let firstHeading = try #require(textView.rotor(headingRotor, resultFor: next))
        #expect(firstHeading.customLabel == "First")

        next.currentItem = firstHeading
        let secondHeading = try #require(textView.rotor(headingRotor, resultFor: next))
        #expect(secondHeading.customLabel == "Second link Alt")

        let filtered = NSAccessibilityCustomRotor.SearchParameters()
        filtered.searchDirection = .next
        filtered.filterString = "LINK"
        let link = try #require(textView.rotor(linkRotor, resultFor: filtered))
        #expect(link.customLabel == "link")

        let image = try #require(textView.rotor(imageRotor, resultFor: next))
        #expect(image.customLabel == "Alt")
    }

    @Test("raw mode exposes source and no rendered-structure rotors")
    func rawMode() {
        let source = "# [Heading](https://example.com)\n"
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = true
        let textView = view(text: source, configuration: configuration)

        #expect(textView.accessibilityString(
            for: NSRange(location: 0, length: (source as NSString).length)
        ) == source)
        #expect(textView.accessibilityCustomRotors().isEmpty)
    }

    @Test("line lookup follows NSString line boundaries")
    func lineLookupSupportsDocumentSeparators() throws {
        let textView = view(text: "alpha\rbeta\u{2028}gamma")
        let visibleString = try #require(textView.accessibilityString(
            for: NSRange(location: 0, length: textView.accessibilityNumberOfCharacters())
        ))
        let visible = visibleString as NSString

        #expect(textView.accessibilityLine(for: visible.range(of: "alpha").location) == 0)
        #expect(textView.accessibilityLine(for: visible.range(of: "beta").location) == 1)
        #expect(textView.accessibilityLine(for: visible.range(of: "gamma").location) == 2)
        #expect(textView.accessibilityRange(forLine: 1) == visible.lineRange(
            for: NSRange(location: visible.range(of: "beta").location, length: 0)
        ))
    }
}

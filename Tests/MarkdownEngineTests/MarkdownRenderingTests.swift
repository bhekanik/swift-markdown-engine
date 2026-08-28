//
//  MarkdownRenderingTests.swift
//  MarkdownEngineTests
//
//  `MarkdownRendering.attributedString` — the styled document without a text
//  view. Its whole point is that it agrees with what the editor shows, so the
//  last test here holds it against a real one.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Headless rendering")
struct MarkdownRenderingTests {

    private func render(_ markdown: String,
                        caret: Int = -1,
                        configuration: MarkdownEditorConfiguration = .default) -> NSAttributedString {
        MarkdownRendering.attributedString(
            for: markdown, fontName: "Helvetica", fontSize: 16,
            caretLocation: caret, configuration: configuration)
    }

    @Test("the characters are the source, untouched")
    func stringIsUnchanged() {
        for source in ["# Heading\n\nSome **bold** and `code`.\n",
                       "- [ ] task\n- [x] done\n",
                       "> quote\n\n```swift\nlet x = 1\n```\n",
                       "",
                       "| a | b |\n| --- | --- |\n| 1 | 2 |\n"] {
            #expect(render(source).string == source)
        }
    }

    @Test("with no caret, every marker is hidden")
    func markersHideWithoutACaret() throws {
        let styled = render("## Section\n")
        let markerFont = try #require(styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let textFont = try #require(styled.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
        #expect(markerFont.pointSize < 1)
        #expect(textFont.pointSize > 16)
    }

    @Test("a caret inside the heading reveals its markers")
    func caretRevealsMarkers() throws {
        let styled = render("## Section\n", caret: 5)
        let markerFont = try #require(styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(markerFont.pointSize > 16)
    }

    @Test("raw source mode returns base attributes only")
    func rawModeIsUnstyled() throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = true
        let styled = render("## Section\n", configuration: configuration)
        let markerFont = try #require(styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let textFont = try #require(styled.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
        #expect(markerFont.pointSize == textFont.pointSize)
    }

    @Test("tracking reaches the base attributes, and 0 leaves .kern unset")
    func trackingIsApplied() throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.paragraph.trackingEm = -0.015
        let tracked = render("plain text\n", configuration: configuration)
        let kern = try #require(tracked.attribute(.kern, at: 2, effectiveRange: nil) as? CGFloat)
        #expect(abs(kern - (16 * -0.015)) < 0.0001)

        let untracked = render("plain text\n")
        #expect(untracked.attribute(.kern, at: 2, effectiveRange: nil) == nil)
    }

    @Test("it agrees with what a real editor puts in its storage")
    func agreesWithTheEditor() throws {
        _ = NSApplication.shared
        let source = "# Title\n\nA **bold** word and a [link](https://example.com).\n\n- one\n- two\n"
        let wrapper = NativeTextViewWrapper(text: .constant(source),
                                            fontName: "Helvetica", fontSize: 16)
        let coordinator = wrapper.makeCoordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        coordinator.adopt(textView, text: source)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let live = try #require(textView.textStorage)
        // Caret at 0 in both, so the same markers are revealed on both sides.
        let headless = render(source, caret: 0)
        #expect(live.string == headless.string)

        for index in 0..<(live.string as NSString).length {
            let liveFont = live.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            let headlessFont = headless.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            #expect(liveFont?.pointSize == headlessFont?.pointSize,
                    "font size differs at \(index)")
            let liveLink = live.attribute(.link, at: index, effectiveRange: nil) != nil
            let headlessLink = headless.attribute(.link, at: index, effectiveRange: nil) != nil
            #expect(liveLink == headlessLink, "link differs at \(index)")
        }
    }
}

@MainActor
@Suite("AppKit adoption")
struct CoordinatorAdoptTests {

    @Test("adopt wires the delegate, styles the document and attaches the controller")
    func adoptWiresEverything() throws {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let wrapper = NativeTextViewWrapper(text: .constant(""), controller: controller,
                                            fontName: "Helvetica", fontSize: 16)
        let coordinator = wrapper.makeCoordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))

        coordinator.adopt(textView, text: "## Section\n\nBody.\n")

        #expect(textView.delegate === coordinator)
        #expect(textView.string == "## Section\n\nBody.\n")
        #expect(controller.textView === textView)
        let markerFont = try #require(
            textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(markerFont.pointSize < 1)

        // And the patch path works on an adopted view.
        #expect(controller.applyPatch(range: NSRange(location: 3, length: 7), replacement: "Chapter"))
        #expect(textView.string == "## Chapter\n\nBody.\n")
    }

    @Test("UndoPolicy.external switches allowsUndo off through adopt")
    func adoptRespectsUndoPolicy() {
        _ = NSApplication.shared
        var configuration = MarkdownEditorConfiguration.default
        configuration.undo = .external
        let wrapper = NativeTextViewWrapper(text: .constant(""), configuration: configuration,
                                            fontName: "Helvetica", fontSize: 16)
        let coordinator = wrapper.makeCoordinator()
        let textView = NSTextView(frame: .zero)
        coordinator.adopt(textView, text: "text")
        #expect(textView.allowsUndo == false)
    }
}

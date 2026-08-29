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

    /// A table is the one construct whose styling resolves colours against an
    /// appearance, and it used to reach for `NSApp.effectiveAppearance`. `NSApp`
    /// is an implicitly unwrapped optional that is nil until something touches
    /// `NSApplication.shared`, so this did not render in the wrong palette — it
    /// killed the process with no test failure to read.
    ///
    /// Another test in this file does touch `NSApplication.shared`, and the
    /// order is not guaranteed, so run it alone to see the regression:
    /// `swift test --filter tableRendersHeadless` traps on the old code.
    @Test("a table renders with no NSApplication in the process")
    func tableRendersHeadless() {
        let source = """
        | year | depth |
        | ---: | :---- |
        | 1900 | 12 cm |

        After the table.
        """
        let styled = render(source)
        #expect(styled.string == source)
        #expect(styled.length > 0)
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

    private final class ReentrantSyntaxHighlighter: SyntaxHighlighter, @unchecked Sendable {
        var onHighlight: (() -> Void)?

        func codeFont(size: CGFloat) -> PlatformFont {
            PlainTextSyntaxHighlighter().codeFont(size: size)
        }

        func backgroundColor() -> PlatformColor {
            PlainTextSyntaxHighlighter().backgroundColor()
        }

        func highlight(code: String, language: String?) -> NSAttributedString? {
            onHighlight?()
            return nil
        }

        var appearanceDidChangeNotification: Notification.Name? { nil }
    }

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

    @Test("an occupied controller leaves a second adopted view isolated")
    func occupiedControllerRefusesAdoptionWithoutLedgerEffects() {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let firstCoordinator = NativeTextViewWrapper(
            text: .constant("alpha"),
            controller: controller
        ).makeCoordinator()
        let first = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        #expect(firstCoordinator.adopt(first, text: "alpha"))

        var secondMutations: [MarkdownTextMutation] = []
        let secondCoordinator = NativeTextViewWrapper(
            text: .constant("bravo"),
            controller: controller,
            onTextMutation: { secondMutations.append($0) }
        ).makeCoordinator()
        let second = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))

        #expect(secondCoordinator.adopt(second, text: "bravo") == false)
        #expect(controller.textView === first)
        #expect(first.string == "alpha")
        #expect(second.string == "bravo")
        #expect(first.textLayoutManager?.textContentManager === controller.textContentStorage)
        #expect(second.textLayoutManager?.textContentManager !== controller.textContentStorage)

        let replacement = NSTextView(frame: .zero)
        replacement.string = "charlie"
        #expect(firstCoordinator.adopt(replacement, text: "charlie") == false)
        #expect(controller.textView === first)
        #expect(firstCoordinator.textView === first)
        #expect(replacement.string == "charlie")

        second.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(second.string == "bravo!")
        #expect(first.string == "alpha")
        #expect(secondMutations.isEmpty)
        #expect(controller.documentRevision == 0)
        #expect(controller.documentMutationDelta == 0)
        #expect(controller.documentPublishedDelta == 0)

        controller.detach(textView: second)
        #expect(controller.textView === first)
        controller.detach(textView: first)
        #expect(secondCoordinator.adopt(second, text: "stale"))
        #expect(controller.textView === second)
        #expect(second.string == "alpha")
        #expect(second.selectedRange() == NSRange(location: 5, length: 0))
        #expect(second.textLayoutManager?.textContentManager === controller.textContentStorage)
        #expect(controller.textContentStorage.textLayoutManagers.count == 1)

        #expect(controller.applyPatch(
            range: NSRange(location: 5, length: 0),
            replacement: "?"
        ))
        #expect(second.string == "alpha?")
        #expect(secondMutations == [
            MarkdownTextMutation(range: NSRange(location: 5, length: 0), replacement: "?"),
        ])
        #expect(controller.documentRevision == 1)
        #expect(controller.documentMutationDelta == 1)
        #expect(controller.documentPublishedDelta == 1)
    }

    @Test("adopt announces only after controller storage is live")
    func adoptionCallbackSeesLiveStorage() {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        var callbackText: String?
        var callbackUsesControllerStorage = false
        controller.onAttach = { textView in
            guard let textView else { return }
            callbackText = textView.string
            callbackUsesControllerStorage = textView.textLayoutManager?.textContentManager
                === controller.textContentStorage
            #expect(controller.applyPatch(
                range: NSRange(location: 0, length: 1),
                replacement: "A"
            ))
        }
        let coordinator = NativeTextViewWrapper(
            text: .constant("alpha"),
            controller: controller
        ).makeCoordinator()
        let textView = NSTextView(frame: .zero)

        #expect(coordinator.adopt(textView, text: "alpha"))
        #expect(callbackText == "alpha")
        #expect(callbackUsesControllerStorage)
        #expect(textView.string == "Alpha")
        #expect(controller.documentRevision == 1)
    }

    @Test("reentrant detach during adoption leaves the view isolated")
    func adoptionCallbackCanRejectOwnership() {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        var shouldDetach = true
        controller.onAttach = { textView in
            guard shouldDetach, let textView else { return }
            shouldDetach = false
            controller.detach(textView: textView)
        }
        var mutations: [MarkdownTextMutation] = []
        let coordinator = NativeTextViewWrapper(
            text: .constant("alpha"),
            controller: controller,
            onTextMutation: { mutations.append($0) }
        ).makeCoordinator()
        let textView = NSTextView(frame: .zero)

        #expect(coordinator.adopt(textView, text: "alpha") == false)
        #expect(controller.isAttached == false)
        #expect(textView.string == "alpha")
        #expect(textView.textLayoutManager?.textContentManager !== controller.textContentStorage)
        textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(textView.string == "alpha!")
        #expect(mutations.isEmpty)
        #expect(controller.documentRevision == 0)

        #expect(coordinator.adopt(textView, text: "ignored"))
        #expect(controller.textView === textView)
        #expect(textView.string == "alpha")
    }

    @Test("public adoption rejects service mutations during its rebuild")
    func publicAdoptionRejectsServiceReentry() {
        _ = NSApplication.shared
        let source = "before\n```swift\nlet value = 1\n```\nafter\n"
        let controller = MarkdownEditorController()
        let highlighter = ReentrantSyntaxHighlighter()
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.syntaxHighlighter = highlighter
        var mutations: [MarkdownTextMutation] = []
        let coordinator = NativeTextViewWrapper(
            text: .constant(source),
            configuration: configuration,
            controller: controller,
            onTextMutation: { mutations.append($0) }
        ).makeCoordinator()
        let textView = NSTextView(frame: .zero)
        var nestedResult: Bool?
        highlighter.onHighlight = {
            guard nestedResult == nil else { return }
            nestedResult = controller.applyPatch(
                range: NSRange(location: 0, length: 1),
                replacement: "B"
            )
        }

        #expect(coordinator.adopt(textView, text: source))
        #expect(nestedResult == false)
        #expect(textView.string == source)
        #expect(mutations.isEmpty)
        #expect(controller.documentRevision == 0)
        #expect(controller.documentMutationDelta == 0)
        #expect(controller.documentPublishedDelta == 0)
    }

    @Test("initial SwiftUI rebuild rejects service mutations")
    func initialSwiftUIRebuildRejectsServiceReentry() throws {
        _ = NSApplication.shared
        let source = "before\n```swift\nlet value = 1\n```\nafter\n"
        let controller = MarkdownEditorController()
        let highlighter = ReentrantSyntaxHighlighter()
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.syntaxHighlighter = highlighter
        var mutations: [MarkdownTextMutation] = []
        var nestedResult: Bool?
        highlighter.onHighlight = {
            guard nestedResult == nil else { return }
            nestedResult = controller.applyPatch(
                range: NSRange(location: 0, length: 1),
                replacement: "B"
            )
        }
        let host = NSHostingView(rootView: NativeTextViewWrapper(
            text: .constant(source),
            configuration: configuration,
            controller: controller,
            onTextMutation: { mutations.append($0) }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let textView = try #require(controller.textView)

        #expect(nestedResult == false)
        #expect(textView.string == source)
        #expect(mutations.isEmpty)
        #expect(controller.documentRevision == 0)
        #expect(controller.documentMutationDelta == 0)
        #expect(controller.documentPublishedDelta == 0)
    }

    @Test("selection restyling rejects service mutations")
    func selectionRestyleRejectsServiceReentry() {
        _ = NSApplication.shared
        let source = "before\n```swift\nlet value = 1\n```\nafter\n"
        let controller = MarkdownEditorController()
        let highlighter = ReentrantSyntaxHighlighter()
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.syntaxHighlighter = highlighter
        var mutations: [MarkdownTextMutation] = []
        let coordinator = NativeTextViewWrapper(
            text: .constant(source),
            configuration: configuration,
            controller: controller,
            onTextMutation: { mutations.append($0) }
        ).makeCoordinator()
        let textView = NSTextView(frame: .zero)
        #expect(coordinator.adopt(textView, text: source))

        var nestedResult: Bool?
        highlighter.onHighlight = {
            guard nestedResult == nil else { return }
            nestedResult = controller.applyPatch(
                range: NSRange(location: 0, length: (controller.text as NSString).length),
                replacement: ""
            )
        }
        textView.setSelectedRange((source as NSString).range(of: "value"))

        #expect(nestedResult == false)
        #expect(textView.string == source)
        #expect(mutations.isEmpty)
        #expect(controller.documentRevision == 0)
        #expect(controller.documentMutationDelta == 0)
        #expect(controller.documentPublishedDelta == 0)
    }

    @Test("selection notifications cannot mutate the document mid-handler")
    func selectionNotificationRejectsReentry() {
        _ = NSApplication.shared
        let source = "**bold** tail\n"
        let notificationName = Notification.Name("CoordinatorAdoptTests.selectionBold")
        let controller = MarkdownEditorController()
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.bus.selectionBoldDidChange = notificationName
        var mutations: [MarkdownTextMutation] = []
        let coordinator = NativeTextViewWrapper(
            text: .constant(source),
            configuration: configuration,
            controller: controller,
            onTextMutation: { mutations.append($0) }
        ).makeCoordinator()
        let textView = NSTextView(frame: .zero)
        #expect(coordinator.adopt(textView, text: source))

        var nestedResult: Bool?
        let observer = NotificationCenter.default.addObserver(
            forName: notificationName,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                guard nestedResult == nil else { return }
                nestedResult = controller.applyPatch(
                    range: NSRange(location: 0, length: (controller.text as NSString).length),
                    replacement: "x"
                )
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        textView.setSelectedRange(NSRange(location: 3, length: 0))

        #expect(nestedResult == false)
        #expect(textView.string == source)
        #expect(mutations.isEmpty)
        #expect(controller.documentRevision == 0)
        #expect(controller.documentMutationDelta == 0)
        #expect(controller.documentPublishedDelta == 0)
    }
}

//
//  MultipleViewsTests.swift
//  MarkdownEngineTests
//
//  One document, two windows. TextKit 2 keeps the text in an
//  `NSTextContentStorage` and lets any number of layout managers lay it out, so
//  the document — not the view — is where that storage belongs. Before this,
//  every wrapper let `NSTextView` auto-create its own stack, so two windows on
//  "the same document" were two unrelated copies kept in step by a binding, and
//  the controller remembered only the most recently attached view: closing
//  either window left the other one unreachable.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("One document in several views")
struct MultipleViewsTests {

    /// A second view on the same document: its own layout manager and
    /// container, the controller's content storage.
    private func addView(to controller: MarkdownEditorController,
                         text: String) -> (NSTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let wrapper = NativeTextViewWrapper(text: .constant(text), controller: controller,
                                            fontName: "Helvetica", fontSize: 16)
        let coordinator = wrapper.makeCoordinator()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        controller.textContentStorage.addTextLayoutManager(layoutManager)
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400),
                                      textContainer: container)
        textView.isEditable = true
        coordinator.adopt(textView, text: text)
        return (textView, coordinator)
    }

    @Test("both views share one content storage")
    func viewsShareOneStorage() {
        let controller = MarkdownEditorController()
        let (first, _) = addView(to: controller, text: "alpha bravo\n")
        let (second, _) = addView(to: controller, text: "alpha bravo\n")

        #expect(first !== second)
        #expect(first.textContentStorage === controller.textContentStorage)
        #expect(second.textContentStorage === controller.textContentStorage)
        #expect(first.textLayoutManager !== second.textLayoutManager,
                "the two views must lay the document out separately")
    }

    @Test("a patch through the controller reaches every view")
    func patchReachesEveryView() {
        let controller = MarkdownEditorController()
        let (first, _) = addView(to: controller, text: "alpha bravo\n")
        let (second, _) = addView(to: controller, text: "alpha bravo\n")

        #expect(controller.applyPatch(range: NSRange(location: 6, length: 5),
                                      replacement: "DELTA"))

        #expect(first.string == "alpha DELTA\n")
        #expect(second.string == "alpha DELTA\n",
                "the second window still shows the old text")
    }

    @Test("typing in one view appears in the other")
    func typingReachesTheOtherView() {
        let controller = MarkdownEditorController()
        let (first, _) = addView(to: controller, text: "alpha\n")
        let (second, _) = addView(to: controller, text: "alpha\n")

        first.insertText("!", replacementRange: NSRange(location: 5, length: 0))

        #expect(first.string == "alpha!\n")
        #expect(second.string == "alpha!\n")
    }

    @Test("closing one window leaves the other live")
    func detachingOneKeepsTheOther() {
        let controller = MarkdownEditorController()
        let (first, _) = addView(to: controller, text: "alpha bravo\n")
        let (second, _) = addView(to: controller, text: "alpha bravo\n")
        #expect(controller.textViews.count == 2)

        controller.detach(textView: second)

        #expect(controller.isAttached, "closing one window silenced the document entirely")
        #expect(controller.textView === first)
        #expect(controller.textViews.count == 1)
        #expect(controller.applyPatch(range: NSRange(location: 0, length: 5),
                                      replacement: "ALPHA"))
        #expect(first.string == "ALPHA bravo\n")
    }

    @Test("detaching the last view leaves the controller inert")
    func detachingBothIsInert() {
        let controller = MarkdownEditorController()
        let (first, _) = addView(to: controller, text: "alpha\n")
        let (second, _) = addView(to: controller, text: "alpha\n")
        controller.detach(textView: first)
        controller.detach(textView: second)

        #expect(controller.isAttached == false)
        #expect(controller.applyPatch(range: NSRange(location: 0, length: 1),
                                      replacement: "b") == false)
    }

    @Test("detaching a view that was never attached changes nothing")
    func detachingAStrangerIsANoOp() {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let (first, _) = addView(to: controller, text: "alpha\n")
        controller.detach(textView: NSTextView(frame: .zero))
        #expect(controller.textView === first)
    }

    @Test("each view keeps its own selection")
    func selectionsAreIndependent() {
        let controller = MarkdownEditorController()
        let (first, _) = addView(to: controller, text: "alpha bravo charlie\n")
        let (second, _) = addView(to: controller, text: "alpha bravo charlie\n")

        first.setSelectedRange(NSRange(location: 2, length: 0))
        second.setSelectedRange(NSRange(location: 14, length: 0))

        #expect(first.selectedRange() == NSRange(location: 2, length: 0))
        #expect(second.selectedRange() == NSRange(location: 14, length: 0))
    }
}

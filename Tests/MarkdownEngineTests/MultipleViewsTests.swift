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

    @Test("detaching drops the layout manager off the storage")
    func detachReleasesTheLayoutManager() {
        let controller = MarkdownEditorController()
        let (first, _) = addView(to: controller, text: "alpha\n")
        let (second, _) = addView(to: controller, text: "alpha\n")
        #expect(controller.textContentStorage.textLayoutManagers.count == 2)

        controller.detach(textView: second)

        #expect(controller.textContentStorage.textLayoutManagers.count == 1,
                "the closed window's layout manager is still laying the document out")
        #expect(second.textLayoutManager?.textContentManager == nil)
        #expect(first.textLayoutManager?.textContentManager === controller.textContentStorage)
    }

    /// A same-length edit changes neither the length nor the other
    /// coordinator's own generation counter, so its memoised parse looked valid
    /// and the second window kept styling syntax that was no longer there.
    @Test("a same-length edit in one view invalidates the other's parse")
    func sameLengthEditInvalidatesTheOtherParse() {
        let controller = MarkdownEditorController()
        let (first, firstCoordinator) = addView(to: controller, text: "*a* and more text here\n")
        let (second, secondCoordinator) = addView(to: controller, text: "*a* and more text here\n")

        // Warm both caches.
        _ = firstCoordinator.parsedDocument(for: first.string)
        _ = secondCoordinator.parsedDocument(for: second.string)

        // `*a*` -> `**a` : same length, different syntax.
        #expect(controller.applyPatch(range: NSRange(location: 0, length: 3),
                                      replacement: "**a"))

        // The controller applies through the most recently attached view, so
        // it is the FIRST view whose cache nothing has bumped.
        let live = first.string
        let reference = MarkdownTokenizer.parseTokensViaAST(in: live, registry: .empty)
        let firstTokens = firstCoordinator.parsedDocument(for: live).tokens
        #expect(firstTokens.count == reference.count,
                "the other view parsed the old syntax")
        #expect(zip(firstTokens, reference).allSatisfy { $0.range == $1.range })
    }

    // MARK: - One presentation per controller

    @Test("a view in a different presentation is refused rather than corrupting the storage")
    func mismatchedPresentationIsRefused() {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        #expect(controller.accepts(rawSourceMode: false, isEditable: true))
        _ = addView(to: controller, text: "## Section\n")

        #expect(controller.accepts(rawSourceMode: false, isEditable: true))
        #expect(controller.accepts(rawSourceMode: true, isEditable: true) == false,
                "a raw view would rewrite the rich view's attributes")
        #expect(controller.accepts(rawSourceMode: false, isEditable: false) == false,
                "a preview view would hide the rich view's revealed markers")
    }

    @Test("the presentation lock lifts when the last view goes")
    func presentationResetsOnLastDetach() {
        let controller = MarkdownEditorController()
        let (view, _) = addView(to: controller, text: "## Section\n")
        #expect(controller.accepts(rawSourceMode: true, isEditable: true) == false)
        controller.detach(textView: view)
        #expect(controller.accepts(rawSourceMode: true, isEditable: true))
    }

    // MARK: - Swapping which document a view shows

    @Test("moving a view to another controller moves its layout manager too")
    func swappingControllerMovesTheStack() {
        _ = NSApplication.shared
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        let (shared, _) = addView(to: documentA, text: "document A\n")
        let (otherWindowOnA, _) = addView(to: documentA, text: "document A\n")

        // The sequence `updateNSView` runs when the embedder hands this view a
        // different controller: detach from A (which drops the layout manager
        // off A's storage), move the manager to B, then rebuild on B.
        documentA.detach(textView: shared)
        if let layoutManager = shared.textLayoutManager {
            documentB.adopt(layoutManager: layoutManager)
        }
        let rebuilt = NativeTextViewWrapper(
            text: .constant("document B\n"), controller: documentB,
            fontName: "Helvetica", fontSize: 16).makeCoordinator()
        rebuilt.adopt(shared, text: "document B\n")

        #expect(shared.textLayoutManager?.textContentManager === documentB.textContentStorage,
                "the view still lays out through document A's storage")
        #expect(documentA.textContentStorage.textLayoutManagers.count == 1,
                "document A kept the moved layout manager")
        #expect(documentA.textView === otherWindowOnA,
                "the window still open on document A lost its controller")
        #expect(shared.string == "document B\n")
        #expect(otherWindowOnA.string == "document A\n",
                "loading document B overwrote document A")

        // And B's own edits land in B, not in A.
        #expect(documentB.applyPatch(range: NSRange(location: 10, length: 0), replacement: "!"))
        #expect(shared.string == "document B!\n")
        #expect(otherWindowOnA.string == "document A\n")
    }
}

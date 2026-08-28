//
//  ControllerSwapTests.swift
//  MarkdownEngineTests
//
//  Handing a live view a different controller means showing a different
//  document in the same window. Two things have to happen atomically: the
//  layout manager moves to the new document's storage, and the selection stops
//  pointing into the old one.
//
//  The second is not cosmetic. AppKit fixes attributes over the selected range
//  on the next attribute write, and `updateNSView` writes `textView.font`
//  shortly after the swap — so a selection past the end of the NEW document
//  traps in `ensureAttributesAreFixedInRange` rather than merely looking wrong.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Swapping which document a view shows")
struct ControllerSwapTests {

    private func coordinator(for controller: MarkdownEditorController,
                             text: String,
                             rawSourceMode: Bool = false) -> NativeTextViewCoordinator {
        _ = NSApplication.shared
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = rawSourceMode
        let wrapper = NativeTextViewWrapper(text: .constant(text), configuration: configuration,
                                            controller: controller,
                                            fontName: "Helvetica", fontSize: 16)
        return wrapper.makeCoordinator()
    }

    private func view(on controller: MarkdownEditorController,
                      text: String,
                      rawSourceMode: Bool = false) -> (NSTextView, NativeTextViewCoordinator) {
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600,
                                                     height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        controller.textContentStorage.addTextLayoutManager(layoutManager)
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400),
                                      textContainer: container)
        textView.isEditable = true
        let coordinator = coordinator(for: controller, text: text, rawSourceMode: rawSourceMode)
        coordinator.adopt(textView, text: text)
        return (textView, coordinator)
    }

    /// The sequence `updateNSView` runs for a controller swap, in order.
    private func swap(_ textView: NSTextView,
                      from old: MarkdownEditorController,
                      to new: MarkdownEditorController,
                      text: String) -> NativeTextViewCoordinator {
        old.detach(textView: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if let layoutManager = textView.textLayoutManager { new.adopt(layoutManager: layoutManager) }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // updateNSView writes the font BEFORE the rebuild, and that is the
        // attribute write that makes AppKit fix attributes over the selected
        // range. Reproducing the order is the whole point: rebuilding first
        // would reset the selection for us and hide the bug.
        textView.font = NSFont(name: "Helvetica", size: 16)
        let rebuilt = coordinator(for: new, text: text)
        rebuilt.adopt(textView, text: text)
        return rebuilt
    }

    @Test("a non-zero selection into a longer document does not trap on a shorter one")
    func selectionFromLongerDocumentIsSafe() {
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        let longText = String(repeating: "alpha bravo charlie delta echo\n", count: 40)
        let (textView, _) = view(on: documentA, text: longText)

        // Selected near the end of A — well past the end of B.
        let tail = (longText as NSString).length - 20
        textView.setSelectedRange(NSRange(location: tail, length: 15))

        // Step through the swap by hand, because the invariant this is about
        // holds only for the window between moving the storage and rebuilding
        // — which is exactly where updateNSView writes the font, and where
        // AppKit fixes attributes over the selected range.
        documentA.detach(textView: textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if let layoutManager = textView.textLayoutManager {
            documentB.adopt(layoutManager: layoutManager)
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let liveLength = (textView.string as NSString).length
        #expect(NSMaxRange(textView.selectedRange()) <= liveLength,
                "the selection points past the end of the document now under the view")
        // The write that trapped in ensureAttributesAreFixedInRange.
        textView.font = NSFont(name: "Helvetica", size: 16)

        let rebuilt = coordinator(for: documentB, text: "short\n")
        rebuilt.adopt(textView, text: "short\n")
        #expect(textView.string == "short\n")
        #expect(NSMaxRange(textView.selectedRange()) <= (textView.string as NSString).length)
    }

    @Test("swapping to an empty document is safe")
    func swapToEmptyDocument() {
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        let (textView, _) = view(on: documentA, text: "alpha bravo charlie\n")
        textView.setSelectedRange(NSRange(location: 6, length: 5))

        _ = swap(textView, from: documentA, to: documentB, text: "")

        #expect(textView.string == "")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
        textView.font = NSFont(name: "Helvetica", size: 16)
    }

    @Test("the delegate and the storage both follow the swap")
    func delegateAndStorageFollow() {
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        let (textView, _) = view(on: documentA, text: "document A\n")

        let rebuilt = swap(textView, from: documentA, to: documentB, text: "document B\n")

        #expect(textView.delegate === rebuilt)
        #expect(textView.textLayoutManager?.textContentManager === documentB.textContentStorage)
        #expect(documentA.textContentStorage.textLayoutManagers.isEmpty)
        #expect(documentB.textViews.count == 1)
    }

    @Test("editing after a swap lands in the new document only")
    func editsLandInTheNewDocument() {
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        let (otherWindowOnA, _) = view(on: documentA, text: "document A\n")
        let (textView, _) = view(on: documentA, text: "document A\n")

        _ = swap(textView, from: documentA, to: documentB, text: "document B\n")

        #expect(documentB.applyPatch(range: NSRange(location: 10, length: 0), replacement: "!"))
        #expect(textView.string == "document B!\n")
        #expect(otherWindowOnA.string == "document A\n",
                "an edit to document B reached document A")
    }

    // MARK: - The presentation lock

    @Test("a second view in a different presentation is refused before anything moves")
    func mismatchedPresentationRefusedUpFront() {
        let controller = MarkdownEditorController()
        let (rich, _) = view(on: controller, text: "## Section\n")

        // Asked on behalf of a NEW view, with the rich one still attached.
        #expect(controller.canPresent(rawSourceMode: true, isEditable: true, from: nil) == false)
        #expect(controller.canPresent(rawSourceMode: false, isEditable: false, from: nil) == false)
        #expect(controller.canPresent(rawSourceMode: false, isEditable: true, from: nil))
        #expect(rich.string == "## Section\n")
    }

    @Test("the only view may change its own presentation")
    func soleViewMayChangePresentation() {
        let controller = MarkdownEditorController()
        let (only, _) = view(on: controller, text: "## Section\n")

        // Switching the lens in a single window is the ordinary case.
        #expect(controller.canPresent(rawSourceMode: true, isEditable: true, from: only))
        #expect(controller.canPresent(rawSourceMode: false, isEditable: false, from: only))
    }

    @Test("a view cannot change presentation while another view is attached")
    func presentationLockedByPeers() {
        let controller = MarkdownEditorController()
        let (first, _) = view(on: controller, text: "## Section\n")
        let (second, _) = view(on: controller, text: "## Section\n")

        #expect(controller.canPresent(rawSourceMode: true, isEditable: true, from: first) == false,
                "one window switching to raw would rewrite the other's attributes")
        #expect(controller.canPresent(rawSourceMode: true, isEditable: true, from: second) == false)
        // Same presentation is always fine.
        #expect(controller.canPresent(rawSourceMode: false, isEditable: true, from: first))
    }

    @Test("the lock lifts once the peers are gone")
    func lockLiftsWithPeers() {
        let controller = MarkdownEditorController()
        let (first, _) = view(on: controller, text: "## Section\n")
        let (second, _) = view(on: controller, text: "## Section\n")
        #expect(controller.canPresent(rawSourceMode: true, isEditable: true, from: first) == false)

        controller.detach(textView: second)

        #expect(controller.canPresent(rawSourceMode: true, isEditable: true, from: first))
    }
}

//
//  SingleViewTests.swift
//  MarkdownEngineTests
//
//  One attached view per controller.
//
//  Marker hiding is a font size and a kern, so presentation-dependent styling
//  has to be written into the content storage itself. Two views over one
//  storage therefore overwrite each other's attributes, and no arrangement of
//  rendering attributes can fix it — TextKit 2 rendering attributes cannot
//  collapse a marker's advance. So a controller drives exactly one view, and
//  two windows on one document are two controllers kept in step by forwarding
//  the edit descriptors between them (`twoControllersStayInSync` below is that
//  model in miniature).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("One view per controller")
struct SingleViewTests {

    /// A view on `controller`'s storage, driven by a coordinator, without
    /// SwiftUI — the AppKit entry point.
    private func view(on controller: MarkdownEditorController,
                      text: String) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600,
                                                     height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        controller.textContentStorage.addTextLayoutManager(layoutManager)
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400),
                                      textContainer: container)
        textView.isEditable = true
        let coordinator = NativeTextViewWrapper(text: .constant(text), controller: controller,
                                                fontName: "Helvetica", fontSize: 16)
            .makeCoordinator()
        coordinator.adopt(textView, text: text)
        return (textView, coordinator)
    }

    private func textViews(in view: NSView) -> [NativeTextView] {
        let here = (view as? NativeTextView).map { [$0] } ?? []
        return here + view.subviews.flatMap(textViews)
    }

    // MARK: - The contract

    @Test("a second view is refused")
    func secondAttachIsRefused() {
        let controller = MarkdownEditorController()
        let (first, _) = view(on: controller, text: "alpha\n")
        let second = NativeTextView(frame: .zero)
        let coordinator = NativeTextViewWrapper(text: .constant("alpha\n"), controller: controller,
                                                fontName: "Helvetica", fontSize: 16)
            .makeCoordinator()

        #expect(controller.attach(textView: second, coordinator: coordinator) == false)
        #expect(controller.textView === first, "the second view took the document")
    }

    @Test("re-attaching the same view is not a second attach")
    func reattachingTheSameViewIsFine() {
        let controller = MarkdownEditorController()
        let (only, coordinator) = view(on: controller, text: "alpha\n")

        #expect(controller.attach(textView: only, coordinator: coordinator))
        #expect(controller.textView === only)
    }

    @Test("detaching frees the slot")
    func detachFreesTheSlot() {
        let controller = MarkdownEditorController()
        let (first, _) = view(on: controller, text: "alpha\n")
        controller.detach(textView: first)
        #expect(controller.isAttached == false)

        let (second, _) = view(on: controller, text: "alpha\n")
        #expect(controller.textView === second)
    }

    @Test("detaching drops the layout manager off the storage")
    func detachReleasesTheLayoutManager() {
        let controller = MarkdownEditorController()
        let (only, _) = view(on: controller, text: "alpha\n")
        #expect(controller.textContentStorage.textLayoutManagers.count == 1)

        controller.detach(textView: only)

        #expect(controller.textContentStorage.textLayoutManagers.isEmpty,
                "the closed window's layout manager is still laying the document out")
        #expect(only.textLayoutManager?.textContentManager == nil)
    }

    @Test("detaching a view that was never attached changes nothing")
    func detachingAStrangerIsANoOp() {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let (only, _) = view(on: controller, text: "alpha\n")
        controller.detach(textView: NSTextView(frame: .zero))
        #expect(controller.textView === only)
    }

    @Test("the last view going leaves the controller inert")
    func detachingLeavesTheControllerInert() {
        let controller = MarkdownEditorController()
        let (only, _) = view(on: controller, text: "alpha\n")
        controller.detach(textView: only)

        #expect(controller.isAttached == false)
        #expect(controller.applyPatch(range: NSRange(location: 0, length: 1),
                                      replacement: "b") == false)
    }

    // MARK: - A refused view reaches nothing

    private struct TwoViewHost: View {
        let controller: MarkdownEditorController
        let text: String
        let onTextMutation: (MarkdownTextMutation) -> Void
        var body: some View {
            VStack(spacing: 0) {
                NativeTextViewWrapper(text: .constant(text), controller: controller,
                                      fontName: "Helvetica", fontSize: 16,
                                      onTextMutation: onTextMutation)
                NativeTextViewWrapper(text: .constant(text), controller: controller,
                                      fontName: "Helvetica", fontSize: 16,
                                      onTextMutation: onTextMutation)
            }
        }
    }

    /// The composition mistake, mounted: two editors wired to one controller.
    /// The second must stay off the document entirely — not share its storage,
    /// not write its text, not be reachable through it.
    @Test("a mounted second view never joins the document's storage")
    func refusedViewIsIsolated() throws {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        var mutations: [MarkdownTextMutation] = []
        let host = NSHostingView(rootView: TwoViewHost(controller: controller, text: "alpha\n",
                                                       onTextMutation: { mutations.append($0) }))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        host.layoutSubtreeIfNeeded()

        let views = textViews(in: host)
        #expect(views.count == 2)
        let attached = try #require(controller.textView)
        let refused = try #require(views.first { $0 !== attached })

        #expect(controller.textContentStorage.textLayoutManagers.count == 1,
                "the refused view put a second layout manager on the document")
        #expect(refused.textLayoutManager?.textContentManager !== controller.textContentStorage,
                "the refused view is laying out the document it was refused")

        // And it cannot edit the document either: typing in it moves only its
        // own text, and a patch through the controller never reaches it.
        refused.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(attached.string == "alpha\n", "the refused view edited the document")
        #expect(mutations.isEmpty,
                "the refused view published its keystroke as an edit to the document")

        #expect(controller.applyPatch(range: NSRange(location: 0, length: 5),
                                      replacement: "ALPHA"))
        #expect(attached.string == "ALPHA\n")
        #expect(refused.string.hasPrefix("alpha"), "the refused view received the document's edit")
    }

    // MARK: - Remount

    private struct IdentityHost: View {
        let controller: MarkdownEditorController
        let identity: Int
        var body: some View {
            NativeTextViewWrapper(text: .constant("alpha\n"), controller: controller,
                                  fontName: "Helvetica", fontSize: 16)
                .id(identity)
        }
    }

    /// SwiftUI builds a remount's replacement BEFORE dismantling the original
    /// and sends the replacement no further update pass — measured order:
    /// `make(new) → update(new) → dismantle(old)`. So the new view is refused at
    /// build time and can never re-ask. Releasing the controller has to hand it
    /// over, or a remount leaves a live editor that reaches nothing: no
    /// `applyPatch`, no text-view seam, no find, no typewriter scrolling.
    @Test("a remount hands the controller to the replacement view")
    func remountHandsOverTheController() throws {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let host = NSHostingView(rootView: IdentityHost(controller: controller, identity: 1))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let original = try #require(controller.textView)

        host.rootView = IdentityHost(controller: controller, identity: 2)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let attached = try #require(controller.textView, "the remounted view was orphaned")
        #expect(attached !== original)
        #expect(textViews(in: host).contains { $0 === attached },
                "the attached view is not the one on screen")
        #expect(controller.textContentStorage.textLayoutManagers.count == 1)
        // And it is a working editor, not merely a registered one.
        #expect(controller.applyPatch(range: NSRange(location: 0, length: 5),
                                      replacement: "ALPHA"))
        #expect(attached.string == "ALPHA\n")
    }

    // MARK: - Two windows, the supported way

    /// Two windows on one document are two controllers, each with its own
    /// storage, kept in step by forwarding each one's `onTextMutation` into the
    /// other's `applyPatch`. In the app that forwarding is `DocumentSession`'s
    /// patch stream; here it is four lines, which is the point — the engine
    /// needs nothing but the two halves it already has.
    @Test("two controllers stay in sync when their edits are forwarded")
    func twoControllersStayInSync() {
        let left = MarkdownEditorController()
        let right = MarkdownEditorController()
        let source = "alpha bravo charlie\n"
        let (leftView, leftCoordinator) = view(on: left, text: source)
        let (rightView, rightCoordinator) = view(on: right, text: source)

        // The bridge: one side's edit descriptor applied to the other, with a
        // re-entrancy guard so the echo stops there.
        var forwarding = false
        func bridge(_ from: NativeTextViewCoordinator, to other: MarkdownEditorController) {
            from.onTextMutation = { mutation in
                guard !forwarding else { return }
                forwarding = true
                defer { forwarding = false }
                other.applyPatch(range: mutation.range, replacement: mutation.replacement)
            }
        }
        bridge(leftCoordinator, to: right)
        bridge(rightCoordinator, to: left)

        leftView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(leftView.string == "alpha! bravo charlie\n")
        #expect(rightView.string == "alpha! bravo charlie\n",
                "the second window did not receive the first's edit")

        rightView.insertText("?", replacementRange: NSRange(location: 12, length: 0))
        #expect(rightView.string == "alpha! bravo? charlie\n")
        #expect(leftView.string == "alpha! bravo? charlie\n",
                "the first window did not receive the second's edit")

        // Separate storages, separate carets — which is what makes two windows
        // worth having.
        #expect(leftView.textContentStorage !== rightView.textContentStorage)
        leftView.setSelectedRange(NSRange(location: 2, length: 0))
        rightView.setSelectedRange(NSRange(location: 14, length: 0))
        #expect(leftView.selectedRange() == NSRange(location: 2, length: 0))
        #expect(rightView.selectedRange() == NSRange(location: 14, length: 0))
    }
}

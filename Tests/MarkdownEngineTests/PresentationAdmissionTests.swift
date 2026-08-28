//
//  PresentationAdmissionTests.swift
//  MarkdownEngineTests
//
//  A document's views share one text storage, and presentation-dependent
//  styling is written into it, so a view in a different presentation is
//  refused. Two things about that refusal have to be true and were not:
//
//  it has to be decided BEFORE the newcomer touches the storage, or a refused
//  view has already added a layout manager and overwritten the peers' text by
//  the time anyone asks; and it has to be RETRIED when the lock changes,
//  because removing the blocking peer and switching the survivor's
//  presentation can arrive in one SwiftUI transaction — the preflight sees the
//  peer, and no further update pass comes to notice it has gone.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Presentation admission")
struct PresentationAdmissionTests {

    private func coordinator(for controller: MarkdownEditorController,
                             text: String,
                             rawSourceMode: Bool) -> NativeTextViewCoordinator {
        _ = NSApplication.shared
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = rawSourceMode
        let wrapper = NativeTextViewWrapper(text: .constant(text), configuration: configuration,
                                            controller: controller,
                                            fontName: "Helvetica", fontSize: 16)
        return wrapper.makeCoordinator()
    }

    /// An admitted view: its layout manager goes on the document's storage.
    @discardableResult
    private func admit(_ controller: MarkdownEditorController,
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

    /// A view built the way `makeNSView` builds a REFUSED one: its own stack,
    /// nothing added to the document's storage.
    private func isolated(_ controller: MarkdownEditorController,
                          text: String,
                          rawSourceMode: Bool) -> (NSTextView, NativeTextViewCoordinator) {
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        let coordinator = coordinator(for: controller, text: text, rawSourceMode: rawSourceMode)
        // Marked BEFORE adopting, exactly as makeNSView decides admission
        // before building anything on the shared storage.
        coordinator.isolatedFromDocument = true
        coordinator.pendingPresentation = (rawSourceMode, true)
        controller.awaitAdmission(coordinator)
        coordinator.adopt(textView, text: text)
        return (textView, coordinator)
    }

    @Test("a refused view never touches the document's storage")
    func refusedViewStaysOff() {
        let controller = MarkdownEditorController()
        let (rich, _) = admit(controller, text: "## Section\n")
        #expect(controller.textContentStorage.textLayoutManagers.count == 1)

        let (raw, _) = isolated(controller, text: "## Section\n", rawSourceMode: true)

        #expect(controller.textContentStorage.textLayoutManagers.count == 1,
                "the refused view added a layout manager to the shared storage")
        #expect(controller.textViews.count == 1)
        #expect(controller.textViews.first === rich)
        #expect(raw.textLayoutManager?.textContentManager !== controller.textContentStorage)
        // And the admitted view's document is untouched.
        #expect(rich.string == "## Section\n")
    }

    @Test("a refused view is admitted when the blocking peer goes away")
    func refusedViewIsAdmittedOnDetach() {
        let controller = MarkdownEditorController()
        let (rich, _) = admit(controller, text: "## Section\n")
        let (raw, rawCoordinator) = isolated(controller, text: "## Section\n", rawSourceMode: true)
        #expect(rawCoordinator.isolatedFromDocument)

        // The peer closes. Nobody is coming to ask again.
        controller.detach(textView: rich)

        #expect(rawCoordinator.isolatedFromDocument == false,
                "the refused view was never admitted after the lock lifted")
        #expect(raw.textLayoutManager?.textContentManager === controller.textContentStorage)
        #expect(controller.textViews.contains { $0 === raw })
        #expect(controller.accepts(rawSourceMode: true, isEditable: true))
        #expect(controller.accepts(rawSourceMode: false, isEditable: true) == false,
                "the lock did not follow the newly admitted view's presentation")
    }

    @Test("an attached view's refused switch is applied when the peer goes away")
    func refusedSwitchAppliedOnDetach() {
        let controller = MarkdownEditorController()
        let (first, firstCoordinator) = admit(controller, text: "## Section\n")
        let (second, _) = admit(controller, text: "## Section\n")

        // The survivor asks for raw while the peer is still attached: refused,
        // and remembered — which is what the wrapper does.
        #expect(controller.canPresent(rawSourceMode: true, isEditable: true, from: first) == false)
        firstCoordinator.pendingPresentation = (rawSourceMode: true, isEditable: true)
        controller.awaitAdmission(firstCoordinator)

        controller.detach(textView: second)

        #expect(firstCoordinator.configuration.rawSourceMode,
                "the switch that was asked for never happened")
        #expect(firstCoordinator.pendingPresentation == nil)
        #expect(controller.accepts(rawSourceMode: true, isEditable: true))
        // Raw leaves the markers at full size; rich collapses them.
        let marker = first.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect((marker?.pointSize ?? 0) > 1, "the document was not restyled for raw")
    }

    @Test("a refusal that is never lifted leaves the document exactly as it was")
    func unliftedRefusalIsInert() {
        let controller = MarkdownEditorController()
        let (rich, _) = admit(controller, text: "## Section\n\nBody.\n")
        let (raw, rawCoordinator) = isolated(controller, text: "## Section\n\nBody.\n",
                                             rawSourceMode: true)

        // An edit in the isolated view reaches nobody.
        raw.insertText("!", replacementRange: NSRange(location: 0, length: 0))

        #expect(rich.string == "## Section\n\nBody.\n",
                "an isolated view's edit reached the shared document")
        #expect(rawCoordinator.isolatedFromDocument)
        #expect(controller.textViews.count == 1)
    }

    @Test("admitting a waiting view does not disturb a peer that is still there")
    func admissionIsScopedToTheWaitingView() {
        let controller = MarkdownEditorController()
        let (first, _) = admit(controller, text: "alpha\n")
        let (second, _) = admit(controller, text: "alpha\n")
        let (raw, rawCoordinator) = isolated(controller, text: "alpha\n", rawSourceMode: true)

        // Only one peer goes; the other still blocks raw.
        controller.detach(textView: second)

        #expect(rawCoordinator.isolatedFromDocument,
                "raw was admitted while a rich peer was still attached")
        #expect(first.string == "alpha\n")
        #expect(controller.textViews.count == 1)
        #expect(raw.textLayoutManager?.textContentManager !== controller.textContentStorage)
    }
}

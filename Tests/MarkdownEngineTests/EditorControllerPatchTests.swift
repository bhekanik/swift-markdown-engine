//
//  EditorControllerPatchTests.swift
//  MarkdownEngineTests
//
//  `MarkdownEditorController.applyPatch` — the external-edit path. The
//  behaviour under test is the one a rebuild cannot give: the caret survives
//  an edit made somewhere else in the document. Headless.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Editor controller patches")
struct EditorControllerPatchTests {

    private final class TextFinderResponder: MarkdownTextFinderActionResponder {
        var onStringWillChange: (() -> Void)?

        func performTextFinderAction(_: NSTextFinder.Action) {}
        func validateTextFinderAction(_: NSTextFinder.Action) -> Bool { false }
        func textFinderClientStringWillChange() { onStringWillChange?() }
    }

    private func makeEditor(
        _ text: String,
        undo: UndoPolicy = .engine,
        onTextMutation: @escaping (MarkdownTextMutation) -> Void = { _ in }
    ) -> (NativeTextView, MarkdownEditorController, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        var configuration = MarkdownEditorConfiguration.default
        configuration.undo = undo
        let wrapper = NativeTextViewWrapper(
            text: .constant(text),
            configuration: configuration,
            controller: controller,
            fontName: "SF Pro",
            fontSize: 16,
            onTextMutation: onTextMutation
        )
        let coordinator = wrapper.makeCoordinator()
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        textView.allowsUndo = undo == .engine
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        coordinator.lastSyncedText = text
        coordinator.previousDisplayLength = (text as NSString).length
        coordinator.didInitialFormatting = true
        controller.attach(textView: textView, coordinator: coordinator)
        return (textView, controller, coordinator)
    }

    // MARK: - Caret preservation

    @Test("a patch after the caret leaves it exactly where it was")
    func patchAfterCaretKeepsIt() {
        let (textView, controller, _) = makeEditor("alpha bravo charlie delta")
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        #expect(controller.applyPatch(range: NSRange(location: 12, length: 7), replacement: "CHARLIE"))

        #expect(textView.string == "alpha bravo CHARLIE delta")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test("a patch before the caret shifts it by the length delta")
    func patchBeforeCaretShiftsIt() {
        let (textView, controller, _) = makeEditor("alpha bravo charlie")
        textView.setSelectedRange(NSRange(location: 12, length: 0))

        #expect(controller.applyPatch(range: NSRange(location: 0, length: 5), replacement: "a"))

        #expect(textView.string == "a bravo charlie")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
    }

    @Test("caret survives a patch far from it in a large document")
    func caretSurvivesPatchInLargeDocument() {
        let paragraph = "The sediment settles into **layers** that record the weather.\n\n"
        let document = String(repeating: paragraph, count: 400)
        let (textView, controller, _) = makeEditor(document)
        let caret = (document as NSString).length - 200
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        #expect(controller.applyPatch(range: NSRange(location: 4, length: 8), replacement: "silt"))

        #expect(textView.selectedRange() == NSRange(location: caret - 4, length: 0))
        #expect((textView.string as NSString).substring(to: 12) == "The silt set")
    }

    @Test("a selection overlapping the patch clamps into the replacement")
    func overlappingSelectionClamps() {
        let (textView, controller, _) = makeEditor("alpha bravo charlie")
        textView.setSelectedRange(NSRange(location: 3, length: 10))

        #expect(controller.applyPatch(range: NSRange(location: 6, length: 5), replacement: "x"))

        #expect(textView.string == "alpha x charlie")
        // start (3) is before the patch and stays; end (13) was past the patch
        // and moves by the -4 delta.
        #expect(textView.selectedRange() == NSRange(location: 3, length: 6))
    }

    // MARK: - Contract

    @Test("the patch is reported through onTextMutation in UTF-16 coordinates")
    func reportsThroughTextMutation() {
        var received: [MarkdownTextMutation] = []
        let (_, controller, coordinator) = makeEditor("alpha bravo") { received.append($0) }
        coordinator.onTextMutation = { received.append($0) }

        #expect(controller.applyPatch(range: NSRange(location: 6, length: 5), replacement: "delta"))

        #expect(received == [MarkdownTextMutation(range: NSRange(location: 6, length: 5),
                                                  replacement: "delta")])
    }

    @Test("an out-of-bounds patch is refused and changes nothing")
    func outOfBoundsRefused() {
        let (textView, controller, _) = makeEditor("alpha")
        #expect(controller.applyPatch(range: NSRange(location: 4, length: 40), replacement: "x") == false)
        #expect(textView.string == "alpha")
    }

    @Test("a detached controller applies nothing")
    func detachedControllerIsInert() {
        let (textView, controller, _) = makeEditor("alpha")
        controller.detach(textView: textView)
        #expect(controller.isAttached == false)
        #expect(controller.applyPatch(range: NSRange(location: 0, length: 1), replacement: "b") == false)
        #expect(textView.string == "alpha")
    }

    @Test("several patches apply as one edit, all addressed pre-edit")
    func multiplePatchesUsePreEditCoordinates() {
        let (textView, controller, _) = makeEditor("one two three")
        textView.setSelectedRange(NSRange(location: 13, length: 0))

        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 0, length: 3), replacement: "1"),
            MarkdownTextPatch(range: NSRange(location: 8, length: 5), replacement: "3"),
        ]))

        #expect(textView.string == "1 two 3")
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
    }

    @Test("a reentrant Finder edit refuses a batch before any requested patch lands")
    func reentrantFinderEditDoesNotPartiallyApplyBatch() {
        var mutations: [MarkdownTextMutation] = []
        let (textView, controller, coordinator) = makeEditor("abcdef") {
            mutations.append($0)
        }
        let responder = TextFinderResponder()
        var didApplyNestedPatch = false
        responder.onStringWillChange = {
            guard !didApplyNestedPatch else { return }
            didApplyNestedPatch = true
            #expect(controller.applyPatch(
                range: NSRange(location: 2, length: 1),
                replacement: "C"
            ))
        }
        controller.textFinderActionResponder = responder

        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 0, length: 1), replacement: "A"),
            MarkdownTextPatch(range: NSRange(location: 5, length: 1), replacement: "F"),
        ]) == false)

        #expect(textView.string == "abCdef")
        #expect(mutations == [MarkdownTextMutation(
            range: NSRange(location: 2, length: 1),
            replacement: "C"
        )])
        #expect(controller.documentRevision == 1)
        #expect(coordinator.pendingTextMutation == nil)
        #expect(coordinator.pendingEditCount == 0)
    }

    @Test("overlapping patches are refused before anything is applied")
    func overlappingPatchesRefused() {
        let (textView, controller, _) = makeEditor("one two three")
        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 0, length: 5), replacement: "x"),
            MarkdownTextPatch(range: NSRange(location: 3, length: 5), replacement: "y"),
        ]) == false)
        #expect(textView.string == "one two three")
    }

    @Test("applyText patches the one changed run and keeps the caret")
    func applyTextPatchesOneRun() {
        let (textView, controller, _) = makeEditor("alpha bravo charlie")
        textView.setSelectedRange(NSRange(location: 18, length: 0))

        #expect(controller.applyText("alpha DELTA charlie"))

        #expect(textView.string == "alpha DELTA charlie")
        #expect(textView.selectedRange() == NSRange(location: 18, length: 0))
    }

    @Test("applyText with identical text is a no-op that reports success")
    func applyTextNoOp() {
        let (textView, controller, _) = makeEditor("alpha")
        #expect(controller.applyText("alpha"))
        #expect(textView.string == "alpha")
    }

    // MARK: - Undo

    @Test("an external patch registers no undo action by default")
    func externalPatchRegistersNoUndo() throws {
        let (textView, controller, coordinator) = makeEditor("alpha bravo")
        let manager = try #require(coordinator.undoManager(for: textView))
        manager.removeAllActions()

        #expect(controller.applyPatch(range: NSRange(location: 0, length: 5), replacement: "x"))

        #expect(manager.canUndo == false)
    }

    @Test("registersUndo: true makes the patch an undo step with its action name")
    func optInUndoRegistersStep() throws {
        let (textView, controller, coordinator) = makeEditor("alpha bravo")
        let manager = try #require(coordinator.undoManager(for: textView))
        manager.removeAllActions()

        #expect(controller.applyPatch(range: NSRange(location: 0, length: 5),
                                      replacement: "x",
                                      actionName: "Apply Suggestion",
                                      registersUndo: true))

        #expect(manager.canUndo)
        #expect(manager.undoActionName == "Apply Suggestion")
    }

    @Test("UndoPolicy.external vends the injected manager and none of its own")
    func externalPolicyVendsInjectedManager() {
        let (textView, controller, coordinator) = makeEditor("alpha", undo: .external)
        #expect(coordinator.undoManager(for: textView) == nil)

        let injected = UndoManager()
        controller.undoManager = injected
        #expect(coordinator.undoManager(for: textView) === injected)
        #expect(coordinator.undoManagers.isEmpty)
    }

    @Test("UndoPolicy.engine still vends a stable per-document manager")
    func enginePolicyUnchanged() {
        let (textView, _, coordinator) = makeEditor("alpha")
        let first = coordinator.undoManager(for: textView)
        #expect(first != nil)
        #expect(coordinator.undoManager(for: textView) === first)
    }

    // MARK: - Text-view seam

    @Test("the controller hands back the live text view and announces attachment")
    func exposesTextView() {
        var announced: [Bool] = []
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        controller.onAttach = { announced.append($0 != nil) }
        #expect(controller.textView == nil)

        let coordinator = NativeTextViewCoordinator(
            text: .constant(""), fontName: "SF Pro", fontSize: 16
        )
        let textView = NativeTextView(frame: .zero)
        controller.attach(textView: textView, coordinator: coordinator)
        #expect(controller.textView === textView)
        controller.detach(textView: textView)
        #expect(controller.textView == nil)
        #expect(announced == [true, false])
    }

    // MARK: - Range transformation

    @Test("range transformation maps every position around the edit")
    func rangeTransformation() {
        let edit = NSRange(location: 10, length: 5)
        // Wholly before.
        #expect(NSRange(location: 2, length: 3).adjusting(forReplacementOf: edit, withLength: 2)
            == NSRange(location: 2, length: 3))
        // Wholly after: shifted by the delta.
        #expect(NSRange(location: 20, length: 3).adjusting(forReplacementOf: edit, withLength: 2)
            == NSRange(location: 17, length: 3))
        // Caret exactly at the edit start stays put.
        #expect(NSRange(location: 10, length: 0).adjusting(forReplacementOf: edit, withLength: 2)
            == NSRange(location: 10, length: 0))
        // Caret inside the replaced span clamps to the replacement's end.
        #expect(NSRange(location: 14, length: 0).adjusting(forReplacementOf: edit, withLength: 2)
            == NSRange(location: 12, length: 0))
        // Pure insertion at the caret leaves the caret before the insertion.
        #expect(NSRange(location: 10, length: 0)
            .adjusting(forReplacementOf: NSRange(location: 10, length: 0), withLength: 4)
            == NSRange(location: 10, length: 0))
    }
}

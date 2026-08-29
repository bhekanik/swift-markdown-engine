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

    private final class CallbackSyntaxHighlighter: SyntaxHighlighter, @unchecked Sendable {
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

    private func makeEditor(
        _ text: String,
        undo: UndoPolicy = .engine,
        syntaxHighlighter: (any SyntaxHighlighter)? = nil,
        onTextMutation: @escaping (MarkdownTextMutation) -> Void = { _ in }
    ) -> (NativeTextView, MarkdownEditorController, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        var configuration = MarkdownEditorConfiguration.default
        configuration.undo = undo
        if let syntaxHighlighter {
            configuration.services.syntaxHighlighter = syntaxHighlighter
        }
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

    @Test("overflowing ranges are refused at every patch boundary")
    func overflowingRangesRefused() {
        var mutations: [MarkdownTextMutation] = []
        let (textView, controller, coordinator) = makeEditor("alpha") {
            mutations.append($0)
        }
        let hostileRanges = [
            NSRange(location: Int.max - 1, length: 100),
            NSRange(location: Int.max, length: 0),
            NSRange(location: 1, length: Int.max),
        ]

        for range in hostileRanges {
            #expect(controller.applyPatch(range: range, replacement: "x") == false)
            #expect(coordinator.applyProgrammaticPatch(
                MarkdownTextPatch(range: range, replacement: "x"),
                to: textView
            ) == false)
            #expect(coordinator.textView(
                textView,
                shouldChangeTextIn: range,
                replacementString: "x"
            ) == false)
        }
        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 0, length: 1), replacement: "A"),
            MarkdownTextPatch(range: hostileRanges[0], replacement: "x"),
        ]) == false)
        #expect(coordinator.textView(
            textView,
            shouldChangeTextInRanges: hostileRanges.map(NSValue.init(range:)),
            replacementStrings: ["x", "x", "x"]
        ) == false)

        #expect(textView.string == "alpha")
        #expect(mutations.isEmpty)
        #expect(controller.documentRevision == 0)
        #expect(coordinator.pendingTextMutation == nil)
        #expect(coordinator.pendingEditCount == 0)
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

    @Test("a same-length reentrant Finder edit invalidates a pending single edit")
    func reentrantFinderEditInvalidatesPendingSingleEdit() {
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

        #expect(coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 0, length: 1),
            replacementString: "A"
        ) == false)

        #expect(textView.string == "abCdef")
        #expect(mutations == [MarkdownTextMutation(
            range: NSRange(location: 2, length: 1),
            replacement: "C"
        )])
        #expect(controller.documentRevision == 1)
        #expect(coordinator.pendingTextMutation == nil)
        #expect(coordinator.pendingEditCount == 0)
    }

    @Test("batch storage and publication finish before callback reentry")
    func batchCallbackReentryRunsAfterRequestedPatches() {
        var mutations: [MarkdownTextMutation] = []
        var binding = "abcdef"
        var nestedBatchReturned = false
        var controller: MarkdownEditorController!
        var textView: NativeTextView!
        (textView, controller, _) = makeEditor("abcdef") { mutation in
            mutations.append(mutation)
            binding = (binding as NSString).replacingCharacters(
                in: mutation.range,
                with: mutation.replacement
            )
            guard mutations.count == 1 else { return }
            #expect(controller.applyPatches([
                MarkdownTextPatch(
                    range: NSRange(location: 0, length: 2),
                    replacement: ""
                ),
            ]))
            #expect(mutations.count == 1)
            nestedBatchReturned = true
            textView.setSelectedRange(NSRange(location: 1, length: 0))
        }
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 0, length: 1), replacement: "A"),
            MarkdownTextPatch(range: NSRange(location: 5, length: 1), replacement: "F"),
        ]))

        #expect(textView.string == "cdeF")
        #expect(binding == "cdeF")
        #expect(nestedBatchReturned)
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
        #expect(mutations == [
            MarkdownTextMutation(range: NSRange(location: 5, length: 1), replacement: "F"),
            MarkdownTextMutation(range: NSRange(location: 0, length: 1), replacement: "A"),
            MarkdownTextMutation(range: NSRange(location: 0, length: 2), replacement: ""),
        ])
        #expect(controller.documentRevision == 3)
    }

    @Test("callback state changes cannot split a batch")
    func batchCallbackCannotRefuseRemainingPatch() throws {
        var mutations: [MarkdownTextMutation] = []
        var binding = "abcdef"
        var textView: NativeTextView!
        let editor = makeEditor("abcdef") { mutation in
            mutations.append(mutation)
            binding = (binding as NSString).replacingCharacters(
                in: mutation.range,
                with: mutation.replacement
            )
            if mutations.count == 1 {
                textView.isEditable = false
            }
        }
        textView = editor.0
        let controller = editor.1
        let undoManager = try #require(editor.2.undoManager(for: textView))
        undoManager.removeAllActions()

        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 0, length: 1), replacement: "A"),
            MarkdownTextPatch(range: NSRange(location: 5, length: 1), replacement: "F"),
        ], actionName: "Batch", registersUndo: true))
        #expect(textView.string == "AbcdeF")
        #expect(binding == "AbcdeF")
        #expect(mutations == [
            MarkdownTextMutation(range: NSRange(location: 5, length: 1), replacement: "F"),
            MarkdownTextMutation(range: NSRange(location: 0, length: 1), replacement: "A"),
        ])

        textView.isEditable = true
        undoManager.undo()
        #expect(textView.string == "abcdef")
    }

    @Test("batch commit rejects edits from styling and selection callbacks")
    func batchRejectsConfiguredCallbackReentry() throws {
        let source = "prefix\n```swift\nabc\n```\nsuffix\n"
        let highlighter = CallbackSyntaxHighlighter()
        var mutations: [MarkdownTextMutation] = []
        var binding = source
        let (textView, controller, coordinator) = makeEditor(
            source,
            syntaxHighlighter: highlighter
        ) { mutation in
            mutations.append(mutation)
            binding = (binding as NSString).replacingCharacters(
                in: mutation.range,
                with: mutation.replacement
            )
        }
        let undoManager = try #require(coordinator.undoManager(for: textView))
        undoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))

        var highlighterResults: [Bool] = []
        var highlighterIsArmed = true
        highlighter.onHighlight = {
            guard highlighterIsArmed else { return }
            highlighterIsArmed = false
            highlighterResults.append(controller.applyPatch(
                range: NSRange(location: 0, length: (controller.text as NSString).length),
                replacement: ""
            ))
            highlighterResults.append(controller.applyPatches([
                MarkdownTextPatch(range: NSRange(location: 0, length: 1), replacement: "X"),
                MarkdownTextPatch(range: NSRange(location: 2, length: 1), replacement: "Y"),
            ]))
        }
        var codeSelectionResults: [Bool] = []
        var codeSelectionIsArmed = true
        coordinator.onCodeBlockSelectionChange = { _ in
            guard codeSelectionIsArmed else { return }
            codeSelectionIsArmed = false
            codeSelectionResults.append(controller.applyPatch(
                range: NSRange(location: 0, length: 1),
                replacement: "Z"
            ))
        }

        let codeRange = (source as NSString).range(of: "abc")
        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 0, length: 1), replacement: "P"),
            MarkdownTextPatch(range: codeRange, replacement: "ABC"),
        ], actionName: "Batch", registersUndo: true))

        let expected = "Prefix\n```swift\nABC\n```\nsuffix\n"
        #expect(textView.string == expected)
        #expect(binding == expected)
        #expect(highlighterResults == [false, false])
        #expect(codeSelectionResults == [false])
        #expect(mutations == [
            MarkdownTextMutation(range: codeRange, replacement: "ABC"),
            MarkdownTextMutation(range: NSRange(location: 0, length: 1), replacement: "P"),
        ])
        #expect(textView.selectedRange() == NSRange(location: (expected as NSString).length, length: 0))
        #expect(controller.documentRevision == 2)
        #expect(controller.documentMutationDelta == 0)
        #expect(controller.documentPublishedDelta == 0)
        #expect(coordinator.pendingTextMutation == nil)
        #expect(coordinator.pendingEditCount == 0)
        #expect(undoManager.canUndo)

        undoManager.undo()
        #expect(textView.string == source)
    }

    @Test("styling callbacks cannot reenter single or user edits")
    func stylingCallbacksCannotReenterOtherEdits() {
        let source = "```swift\nabc\n```\n"
        let highlighter = CallbackSyntaxHighlighter()
        var mutations: [MarkdownTextMutation] = []
        let (textView, controller, _) = makeEditor(
            source,
            syntaxHighlighter: highlighter
        ) { mutations.append($0) }
        var nestedResults: [Bool] = []
        var callbackIsArmed = true
        highlighter.onHighlight = {
            guard callbackIsArmed else { return }
            callbackIsArmed = false
            nestedResults.append(controller.applyPatch(
                range: NSRange(location: 0, length: (controller.text as NSString).length),
                replacement: ""
            ))
        }

        let codeEnd = NSMaxRange((source as NSString).range(of: "abc"))
        textView.insertText("!", replacementRange: NSRange(location: codeEnd, length: 0))
        #expect(nestedResults == [false])
        #expect(textView.string == "```swift\nabc!\n```\n")

        callbackIsArmed = true
        #expect(controller.applyPatch(
            range: NSRange(location: codeEnd, length: 1),
            replacement: "?"
        ))
        #expect(nestedResults == [false, false])
        #expect(textView.string == "```swift\nabc?\n```\n")
        #expect(mutations == [
            MarkdownTextMutation(range: NSRange(location: codeEnd, length: 0), replacement: "!"),
            MarkdownTextMutation(range: NSRange(location: codeEnd, length: 1), replacement: "?"),
        ])
        #expect(controller.documentRevision == 2)
    }

    @Test("a read-only view refuses a batch before commit")
    func readOnlyBatchIsRefusedAtomically() {
        var mutations: [MarkdownTextMutation] = []
        let (textView, controller, _) = makeEditor("abcdef") {
            mutations.append($0)
        }
        textView.isEditable = false

        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 0, length: 1), replacement: "A"),
            MarkdownTextPatch(range: NSRange(location: 5, length: 1), replacement: "F"),
        ]) == false)
        #expect(textView.string == "abcdef")
        #expect(mutations.isEmpty)
        #expect(controller.documentRevision == 0)
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

//
//  WritingToolsMutationTests.swift
//  MarkdownEngineTests
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Writing Tools mutation reporting")
struct WritingToolsMutationTests {
    private func makeAttachedView(
        text: String,
        controller: MarkdownEditorController,
        onTextMutation: @escaping (MarkdownTextMutation) -> Void
    ) -> (NativeTextView, NativeTextViewCoordinator) {
        let wrapper = NativeTextViewWrapper(
            text: .constant(text),
            controller: controller,
            fontName: "Helvetica",
            fontSize: 16,
            onTextMutation: onTextMutation
        )
        let coordinator = wrapper.makeCoordinator()
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
        coordinator.adopt(textView, text: text)
        return (textView, coordinator)
    }

    private func replaceThroughWritingTools(
        in textView: NSTextView,
        range: NSRange,
        with replacement: String
    ) {
        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            Issue.record("text view refused the Writing Tools replacement")
            return
        }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
    }

    private func applying(
        _ mutations: [MarkdownTextMutation],
        to source: String
    ) -> String {
        let result = NSMutableString(string: source)
        for mutation in mutations {
            result.replaceCharacters(in: mutation.range, with: mutation.replacement)
        }
        return result as String
    }

    @available(macOS 15.0, *)
    @Test("an accepted session publishes one reproducible mutation")
    func acceptedSessionPublishesOneMutation() throws {
        _ = NSApplication.shared
        let before = "The quik fox.\n"
        let after = "The quick brown fox.\n"
        var mutations: [MarkdownTextMutation] = []
        let wrapper = NativeTextViewWrapper(
            text: .constant(before),
            fontName: "Helvetica",
            fontSize: 16,
            onTextMutation: { mutations.append($0) }
        )
        let coordinator = wrapper.makeCoordinator()
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.lastSyncedText = before
        coordinator.previousDisplayLength = (before as NSString).length
        textView.string = before

        coordinator.textViewWritingToolsWillBegin(textView)
        textView.string = after
        coordinator.wtDetectedMode = .proofread
        coordinator.pendingEditCount = 3
        coordinator.pendingEditedRange = NSRange(location: 7, length: 8)
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )

        #expect(coordinator.pendingEditCount == 0)
        #expect(coordinator.pendingEditedRange == nil)

        coordinator.textViewWritingToolsDidEnd(textView)

        let mutation = try #require(mutations.first)
        #expect(mutations.count == 1)
        #expect(mutation.range == NSRange(location: 7, length: 1))
        #expect(mutation.replacement == "ck brown")

        let reproduced = NSMutableString(string: before)
        reproduced.replaceCharacters(in: mutation.range, with: mutation.replacement)
        #expect(reproduced as String == after)
    }

    @available(macOS 15.0, *)
    @Test("an external controller patch and Writing Tools publish each character change once")
    func controllerPatchDuringSessionIsNotRepublished() throws {
        _ = NSApplication.shared
        let before = "The quik fox rests.\n"
        let controller = MarkdownEditorController()
        var mutations: [MarkdownTextMutation] = []
        let (textView, coordinator) = makeAttachedView(
            text: before,
            controller: controller,
            onTextMutation: { mutations.append($0) }
        )
        textView.setSelectedRange(NSRange(location: 4, length: 4))
        let undoManager = try #require(coordinator.undoManager(for: textView))
        undoManager.removeAllActions()

        coordinator.textViewWritingToolsWillBegin(textView)
        #expect(controller.applyPatch(
            range: NSRange(location: 13, length: 5),
            replacement: "sleeps"
        ))
        #expect(undoManager.canUndo == false)
        replaceThroughWritingTools(
            in: textView,
            range: NSRange(location: 4, length: 4),
            with: "quick"
        )
        coordinator.textViewWritingToolsDidEnd(textView)

        #expect(mutations == [
            MarkdownTextMutation(range: NSRange(location: 13, length: 5), replacement: "sleeps"),
            MarkdownTextMutation(range: NSRange(location: 7, length: 0), replacement: "c"),
        ])
        #expect(applying(mutations, to: before) == "The quick fox sleeps.\n")
        #expect(textView.string == "The quick fox sleeps.\n")
        #expect(try #require(mutations.last).range.length < (before as NSString).length)
    }

    @available(macOS 15.0, *)
    @Test("a second view edit and Writing Tools publish each character change once")
    func secondViewEditDuringSessionIsNotRepublished() throws {
        _ = NSApplication.shared
        let before = "The quik fox rests.\n"
        let controller = MarkdownEditorController()
        var mutations: [MarkdownTextMutation] = []
        let record: (MarkdownTextMutation) -> Void = { mutations.append($0) }
        let (writingToolsView, writingToolsCoordinator) = makeAttachedView(
            text: before,
            controller: controller,
            onTextMutation: record
        )
        let (secondView, _) = makeAttachedView(
            text: before,
            controller: controller,
            onTextMutation: record
        )
        writingToolsView.setSelectedRange(NSRange(location: 4, length: 4))

        writingToolsCoordinator.textViewWritingToolsWillBegin(writingToolsView)
        secondView.insertText(
            "sleeps",
            replacementRange: NSRange(location: 13, length: 5)
        )
        replaceThroughWritingTools(
            in: writingToolsView,
            range: NSRange(location: 4, length: 4),
            with: "quick"
        )
        writingToolsCoordinator.textViewWritingToolsDidEnd(writingToolsView)

        #expect(mutations == [
            MarkdownTextMutation(range: NSRange(location: 13, length: 5), replacement: "sleeps"),
            MarkdownTextMutation(range: NSRange(location: 7, length: 0), replacement: "c"),
        ])
        #expect(applying(mutations, to: before) == "The quick fox sleeps.\n")
        #expect(writingToolsView.string == "The quick fox sleeps.\n")
        #expect(try #require(mutations.last).range.length < (before as NSString).length)
    }

    @available(macOS 15.0, *)
    @Test("an overlapping controller patch falls back to a reproducible full replacement")
    func overlappingControllerPatchPublishesFullReplacement() throws {
        _ = NSApplication.shared
        let before = "The quik fox rests.\n"
        let after = "The quick fox rests.\n"
        let controller = MarkdownEditorController()
        var mutations: [MarkdownTextMutation] = []
        let (textView, coordinator) = makeAttachedView(
            text: before,
            controller: controller,
            onTextMutation: { mutations.append($0) }
        )
        textView.setSelectedRange(NSRange(location: 4, length: 4))

        coordinator.textViewWritingToolsWillBegin(textView)
        #expect(controller.applyPatch(
            range: NSRange(location: 5, length: 2),
            replacement: "UE"
        ))
        replaceThroughWritingTools(
            in: textView,
            range: NSRange(location: 4, length: 4),
            with: "quick"
        )
        coordinator.textViewWritingToolsDidEnd(textView)

        let finalMutation = try #require(mutations.last)
        #expect(mutations.count == 2)
        #expect(finalMutation.range == NSRange(location: 0, length: (before as NSString).length))
        #expect(applying(mutations, to: before) == after)
        #expect(textView.string == after)
    }

    @available(macOS 15.0, *)
    @Test("a caret-only session with a concurrent edit publishes a reproducible full replacement")
    func caretOnlySessionPublishesFullReplacement() throws {
        _ = NSApplication.shared
        let before = "The quik fox rests.\n"
        let after = "The very quik fox sleeps.\n"
        let controller = MarkdownEditorController()
        var mutations: [MarkdownTextMutation] = []
        let (textView, coordinator) = makeAttachedView(
            text: before,
            controller: controller,
            onTextMutation: { mutations.append($0) }
        )
        textView.setSelectedRange(NSRange(location: 4, length: 0))

        coordinator.textViewWritingToolsWillBegin(textView)
        #expect(controller.applyPatch(
            range: NSRange(location: 13, length: 5),
            replacement: "sleeps"
        ))
        replaceThroughWritingTools(
            in: textView,
            range: NSRange(location: 4, length: 0),
            with: "very "
        )
        coordinator.textViewWritingToolsDidEnd(textView)

        let finalMutation = try #require(mutations.last)
        let listenerLength = (before as NSString).length + 1
        #expect(mutations.count == 2)
        #expect(finalMutation.range == NSRange(location: 0, length: listenerLength))
        #expect(applying(mutations, to: before) == after)
        #expect(textView.string == after)
    }

    @available(macOS 15.0, *)
    @Test("a concurrent edit without an exact record publishes a reproducible full replacement")
    func inexactConcurrentEditPublishesFullReplacement() throws {
        _ = NSApplication.shared
        let before = "The quik fox rests.\n"
        let after = "Aha quick fox sleep.\n"
        let controller = MarkdownEditorController()
        var mutations: [MarkdownTextMutation] = []
        let record: (MarkdownTextMutation) -> Void = { mutations.append($0) }
        let (writingToolsView, writingToolsCoordinator) = makeAttachedView(
            text: before,
            controller: controller,
            onTextMutation: record
        )
        let (secondView, _) = makeAttachedView(
            text: before,
            controller: controller,
            onTextMutation: record
        )
        writingToolsView.setSelectedRange(NSRange(location: 4, length: 4))

        writingToolsCoordinator.textViewWritingToolsWillBegin(writingToolsView)
        #expect(secondView.shouldChangeText(
            in: NSRange(location: 13, length: 5),
            replacementString: "sleep"
        ))
        secondView.textStorage?.replaceCharacters(
            in: NSRange(location: 13, length: 5),
            with: "sleep"
        )
        #expect(secondView.shouldChangeText(
            in: NSRange(location: 0, length: 3),
            replacementString: "Aha"
        ))
        secondView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 3),
            with: "Aha"
        )
        secondView.didChangeText()
        replaceThroughWritingTools(
            in: writingToolsView,
            range: NSRange(location: 4, length: 4),
            with: "quick"
        )
        writingToolsCoordinator.textViewWritingToolsDidEnd(writingToolsView)

        let finalMutation = try #require(mutations.last)
        #expect(mutations.count == 1)
        #expect(finalMutation.range == NSRange(location: 0, length: (before as NSString).length))
        #expect(applying(mutations, to: before) == after)
        #expect(writingToolsView.string == after)
    }
}

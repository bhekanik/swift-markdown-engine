//
//  TextDiffScalarSafetyTests.swift
//  MarkdownEngineTests
//
//  An `NSRange` addresses UTF-16 code units and an emoji is two of them, so a
//  naive prefix/suffix scan over code units can build a replacement out of half
//  a character. The document still comes out right — the storage reassembles it
//  from the units — but the mutation published to the embedder is not valid
//  UTF-8, and a sync outbox that JSON-encodes it fails with no obvious cause.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Diffs and patches respect character boundaries")
struct TextDiffScalarSafetyTests {

    private func makeEditor(_ text: String) -> (NativeTextView, MarkdownEditorController,
                                                NativeTextViewCoordinator, () -> [MarkdownTextMutation]) {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let wrapper = NativeTextViewWrapper(text: .constant(text), controller: controller,
                                            fontName: "Helvetica", fontSize: 16)
        let coordinator = wrapper.makeCoordinator()
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        let box = MutationBox()
        coordinator.onTextMutation = { box.mutations.append($0) }
        coordinator.adopt(textView, text: text)
        return (textView, controller, coordinator, { box.mutations })
    }

    private final class MutationBox { var mutations: [MarkdownTextMutation] = [] }

    /// The published replacement must survive a round trip through UTF-8 —
    /// which is what a sync outbox does to it.
    private func isEncodable(_ mutation: MarkdownTextMutation) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["replacement": mutation.replacement], options: []) else { return false }
        return !data.isEmpty
    }

    @Test("swapping one emoji for another emits a whole character, not a surrogate half")
    func emojiSwapEmitsWholeCharacter() throws {
        // 😀 U+1F600 and 😂 U+1F602 share their high surrogate, so a UTF-16
        // scan puts it in the common prefix and the low surrogate alone in the
        // replacement.
        let (textView, controller, _, mutations) = makeEditor("A😀Z")

        #expect(controller.applyText("A😂Z"))

        #expect(textView.string == "A😂Z")
        let published = try #require(mutations().last)
        #expect(published.replacement == "😂", "published half a character")
        #expect(published.replacement.unicodeScalars.count == 1)
        #expect(isEncodable(published))
    }

    @Test("the same holds for the external splice path")
    func splicePathIsScalarSafe() throws {
        let (textView, _, coordinator, mutations) = makeEditor("A😀Z and a good deal more text\n")

        #expect(coordinator.spliceExternalText("A😂Z and a good deal more text\n", in: textView) == .applied)

        #expect(textView.string == "A😂Z and a good deal more text\n")
        let published = try #require(mutations().last)
        #expect(published.replacement == "😂")
        #expect(isEncodable(published))
    }

    @Test("a diff between emoji reports a two-unit range, not a one-unit one")
    func diffRangeCoversTheWholeCharacter() {
        let patch = MarkdownTextPatch.diff(from: "A😀Z", to: "A😂Z")
        #expect(patch.range == NSRange(location: 1, length: 2))
        #expect(patch.replacement == "😂")
    }

    @Test("a diff that only appends leaves the shared prefix alone")
    func appendDiff() {
        let patch = MarkdownTextPatch.diff(from: "alpha", to: "alpha bravo")
        #expect(patch.range == NSRange(location: 5, length: 0))
        #expect(patch.replacement == " bravo")
    }

    @Test("a diff of identical text is empty")
    func identicalDiff() {
        let patch = MarkdownTextPatch.diff(from: "same", to: "same")
        #expect(patch.range.length == 0)
        #expect(patch.replacement.isEmpty)
    }

    @Test("a patch that bisects a surrogate pair is refused")
    func bisectingPatchRefused() {
        let (textView, controller, _, _) = makeEditor("A😀Z")
        // Location 2 is between the emoji's high and low surrogate.
        #expect(controller.applyPatch(range: NSRange(location: 2, length: 1),
                                      replacement: "x") == false)
        #expect(controller.applyPatch(range: NSRange(location: 1, length: 1),
                                      replacement: "x") == false)
        #expect(textView.string == "A😀Z")
        // The whole character is fine.
        #expect(controller.applyPatch(range: NSRange(location: 1, length: 2), replacement: "x"))
        #expect(textView.string == "AxZ")
    }
}

@MainActor
@Suite("Batch patch semantics")
struct BatchPatchTests {

    private func makeEditor(_ text: String) -> (NativeTextView, MarkdownEditorController,
                                                NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        var configuration = MarkdownEditorConfiguration.default
        configuration.undo = .engine
        let wrapper = NativeTextViewWrapper(text: .constant(text), configuration: configuration,
                                            controller: controller,
                                            fontName: "Helvetica", fontSize: 16)
        let coordinator = wrapper.makeCoordinator()
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        coordinator.adopt(textView, text: text)
        return (textView, controller, coordinator)
    }

    @Test("two insertions at the same offset are refused rather than ordered arbitrarily")
    func coincidentInsertionsRefused() {
        let (textView, controller, _) = makeEditor("alpha")
        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 2, length: 0), replacement: "A"),
            MarkdownTextPatch(range: NSRange(location: 2, length: 0), replacement: "B"),
        ]) == false)
        #expect(textView.string == "alpha", "an ambiguous batch was partly applied")
    }

    @Test("an insertion at the edge of another patch is refused")
    func edgeInsertionRefused() {
        let (textView, controller, _) = makeEditor("alpha bravo")
        // Insert exactly where the replacement begins.
        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 6, length: 5), replacement: "x"),
            MarkdownTextPatch(range: NSRange(location: 6, length: 0), replacement: "y"),
        ]) == false)
        // And exactly where it ends.
        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 0, length: 5), replacement: "x"),
            MarkdownTextPatch(range: NSRange(location: 5, length: 0), replacement: "y"),
        ]) == false)
        #expect(textView.string == "alpha bravo")
    }

    @Test("adjacent non-empty ranges are allowed")
    func adjacentRangesAllowed() {
        let (textView, controller, _) = makeEditor("alpha bravo")
        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 0, length: 5), replacement: "1"),
            MarkdownTextPatch(range: NSRange(location: 5, length: 6), replacement: "2"),
        ]))
        #expect(textView.string == "12")
    }

    @Test("an out-of-bounds patch rejects the whole batch, applying none of it")
    func batchIsAllOrNothing() {
        let (textView, controller, _) = makeEditor("alpha bravo")
        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 0, length: 5), replacement: "1"),
            MarkdownTextPatch(range: NSRange(location: 40, length: 5), replacement: "2"),
        ]) == false)
        #expect(textView.string == "alpha bravo", "a partly-applied batch left a torn document")
    }

    @Test("a batch is one undo action, not one per patch")
    func batchIsOneUndoAction() throws {
        let (textView, controller, coordinator) = makeEditor("one two three")
        let manager = try #require(coordinator.undoManager(for: textView))
        manager.removeAllActions()

        #expect(controller.applyPatches([
            MarkdownTextPatch(range: NSRange(location: 0, length: 3), replacement: "1"),
            MarkdownTextPatch(range: NSRange(location: 8, length: 5), replacement: "3"),
        ], actionName: "Canonicalise", registersUndo: true))
        #expect(textView.string == "1 two 3")
        #expect(manager.undoActionName == "Canonicalise")

        manager.undo()
        #expect(textView.string == "one two three",
                "one undo left the document half-reverted")
    }
}

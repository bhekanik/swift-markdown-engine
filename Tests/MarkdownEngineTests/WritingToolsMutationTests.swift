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
}

//
//  StringSnapshotTests.swift
//  MarkdownEngineTests
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

/// `NativeTextView.string` serves a cached copy of the storage between
/// character edits. Every way the characters can change has to retire it.
@MainActor
@Suite("Text view string snapshot", .serialized)
struct StringSnapshotTests {
    private func makeView(_ text: String) -> NativeTextView {
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.string = text
        return view
    }

    private func live(_ view: NSTextView) -> String {
        view.textStorage!.mutableString as String
    }

    /// Longer than Swift's 15-byte small-string form, which is stored inline
    /// and so never shares an address between copies.
    private static let longText = "alpha beta gamma delta epsilon"

    @Test("repeat reads share one copy until the characters change")
    func repeatReadsShareStorage() {
        let view = makeView(Self.longText)
        let first = view.string
        let second = view.string
        let shared = first.utf8.withContiguousStorageIfAvailable { a in
            second.utf8.withContiguousStorageIfAvailable { b in a.baseAddress == b.baseAddress }
        }
        #expect(shared == .some(.some(true)))
    }

    @Test("every kind of character edit is seen at once")
    func editsInvalidate() {
        let view = makeView("alpha beta")
        _ = view.string
        view.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        #expect(view.string == "Xalpha beta")

        view.textStorage!.replaceCharacters(in: NSRange(location: 1, length: 5), with: "omega")
        #expect(view.string == "Xomega beta")

        view.string = "new document"
        #expect(view.string == "new document")

        // Same length, different characters: a length check alone would miss it.
        view.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 3), with: "old")
        #expect(view.string == "old document")
        #expect(view.string == live(view))
    }

    @Test("attribute-only edits keep the snapshot")
    func attributesDoNotInvalidate() {
        let view = makeView(Self.longText)
        let before = view.string
        view.textStorage!.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 5))
        let after = view.string
        let shared = before.utf8.withContiguousStorageIfAvailable { a in
            after.utf8.withContiguousStorageIfAvailable { b in a.baseAddress == b.baseAddress }
        }
        #expect(shared == .some(.some(true)))
    }

    @Test("a read inside an editing batch sees the batch's characters")
    func midBatchReadsAreLive() {
        let view = makeView("alpha beta")
        _ = view.string
        let storage = view.textStorage!
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "gamma")
        #expect(view.string == "gamma beta")
        storage.endEditing()
        #expect(view.string == "gamma beta")
    }

    @Test("a lone surrogate survives UTF-16 exact")
    func loneSurrogate() {
        let view = makeView("")
        let units: [unichar] = [0x61, 0xD83D, 0x62]
        let text = NSString(characters: units, length: units.count) as String
        view.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        let read = view.string as NSString
        #expect(read.length == 3)
        #expect(read.character(at: 1) == 0xD83D)
        #expect(read.isEqual(to: live(view)))
    }
}

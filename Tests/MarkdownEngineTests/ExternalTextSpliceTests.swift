//
//  ExternalTextSpliceTests.swift
//  MarkdownEngineTests
//
//  An external `text` binding change on the SAME document used to go through
//  `textView.string =`, and AppKit resets the selection to {0, 0} on that
//  assignment — a remote edit dropped the reader's caret at the top of the
//  document. These cover the splice that replaces it. Headless.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("External text splice")
struct ExternalTextSpliceTests {

    private func makeEditor(_ text: String) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let wrapper = NativeTextViewWrapper(text: .constant(text), fontName: "SF Pro", fontSize: 16)
        let coordinator = wrapper.makeCoordinator()
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        coordinator.didInitialFormatting = true
        return (textView, coordinator)
    }

    @Test("a remote edit above the caret keeps the caret on its own word")
    func remoteEditKeepsCaret() {
        let (textView, coordinator) = makeEditor("# Title\n\nfirst paragraph\n\nsecond paragraph\n")
        textView.setSelectedRange(NSRange(location: 32, length: 0))
        let under = (textView.string as NSString).substring(with: NSRange(location: 32, length: 6))

        #expect(coordinator.spliceExternalText("# Retitled\n\nfirst paragraph\n\nsecond paragraph\n",
                                               in: textView))

        #expect(textView.string.hasPrefix("# Retitled"))
        #expect((textView.string as NSString)
            .substring(with: NSRange(location: textView.selectedRange().location, length: 6)) == under)
    }

    @Test("the storage string is exactly the new text")
    func storageMatchesNewText() {
        let (textView, coordinator) = makeEditor("alpha bravo charlie")
        #expect(coordinator.spliceExternalText("alpha DELTA charlie", in: textView))
        #expect(textView.string == "alpha DELTA charlie")
        #expect(coordinator.lastSyncedText == "alpha DELTA charlie")
    }

    @Test("an identical text is a no-op that still reports success")
    func identicalTextIsNoOp() {
        let (textView, coordinator) = makeEditor("alpha")
        #expect(coordinator.spliceExternalText("alpha", in: textView))
        #expect(textView.string == "alpha")
    }

    @Test("a wholesale replacement declines, so the caller falls back to the rebuild")
    func wholesaleReplacementDeclines() {
        let (textView, coordinator) = makeEditor("alpha bravo charlie delta echo")
        #expect(coordinator.spliceExternalText("completely different content here", in: textView) == false)
        #expect(textView.string == "alpha bravo charlie delta echo")
    }

    @Test("styling follows the spliced text: a new heading renders as a heading")
    func splicedTextIsRestyled() throws {
        let (textView, coordinator) = makeEditor("plain line\n\ntrailing\n")
        let baseSize = try #require(
            textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        ).pointSize

        #expect(coordinator.spliceExternalText("## plain line\n\ntrailing\n", in: textView))

        let headingFont = try #require(
            textView.textStorage?.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        )
        #expect(headingFont.pointSize > baseSize)
    }
}

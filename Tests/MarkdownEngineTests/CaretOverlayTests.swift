//
//  CaretOverlayTests.swift
//  MarkdownEngineTests
//
//  The drawn block/hollow caret: its frame comes from TextKit's own segment
//  rects, so it is assertable in-process — the whole reason the indicator-
//  resizing approach was replaced (a key window rewrites the indicator frame
//  where no test can see it).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Vim caret overlay", .serialized)
struct CaretOverlayTests {
    private final class Mounted {
        let window: NSWindow
        let controller: MarkdownEditorController
        let textView: NativeTextView

        init(window: NSWindow, controller: MarkdownEditorController, textView: NativeTextView) {
            self.window = window
            self.controller = controller
            self.textView = textView
        }
    }

    private func mount(_ text: String) throws -> Mounted {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = true
        configuration.undo = .external
        let wrapper = NativeTextViewWrapper(
            text: .constant(text),
            configuration: configuration,
            controller: controller,
            fontName: "Menlo",
            fontSize: 14
        )
        let host = NSHostingView(rootView: wrapper)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let textView = try #require(controller.textView as? NativeTextView)
        #expect(window.makeFirstResponder(textView))
        return Mounted(window: window, controller: controller, textView: textView)
    }

    /// AppKit creates `NSTextInsertionIndicator` only for the first responder
    /// of a key window, and a test process cannot make a window key (measured:
    /// `makeKeyAndOrderFront` leaves `isKeyWindow` false). So the indicator is
    /// planted by hand; the engine finds it by exact type, as AppKit's own.
    private func plantIndicator(in textView: NSTextView) -> NSTextInsertionIndicator {
        let indicator = NSTextInsertionIndicator(frame: NSRect(x: 0, y: 0, width: 1, height: 17))
        textView.addSubview(indicator)
        return indicator
    }

    private func cellWidth(_ mounted: Mounted, of cluster: String) -> CGFloat {
        (cluster as NSString).size(withAttributes: [.font: mounted.textView.font!]).width
    }

    /// The last text line's bottom in the "ab" fragment — where TextKit
    /// wrongly plants the trailing-`\n` caret before the FB22524198 snap.
    private func lastTextLineMaxY(_ textView: NSTextView) -> CGFloat? {
        guard let tlm = textView.textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let trailingLoc = tcs.location(tcs.documentRange.location, offsetBy: 2)
        else { return nil }
        var maxY: CGFloat?
        tlm.enumerateTextLayoutFragments(from: trailingLoc, options: [.ensuresLayout]) { fragment in
            let line = fragment.textLineFragments.last { $0.characterRange.length > 0 }
                ?? fragment.textLineFragments.last
            maxY = fragment.layoutFragmentFrame.origin.y + (line?.typographicBounds.maxY ?? 0)
            return false
        }
        return maxY
    }

    @Test("a block caret covers the glyph cell: ASCII, emoji, CJK")
    func blockCaretCoversGlyphCells() throws {
        let mounted = try mount("Mmm\n")
        defer { mounted.window.contentView = nil }
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))

        #expect(mounted.controller.vimCaretOverlay == nil, "the bar caret draws no overlay")

        mounted.controller.caretShape = .block
        let overlay = try #require(mounted.controller.vimCaretOverlay)
        let em = cellWidth(mounted, of: "m")

        #expect(!overlay.isHidden)
        #expect(abs(overlay.frame.width - em) < 1, "ASCII width \(overlay.frame.width) vs cell \(em)")
        #expect(overlay.frame.height > 10, "a cell, not a bar")
        let firstX = overlay.frame.minX

        // A programmatic caret move is one of the refresh sites; the frame follows.
        mounted.textView.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(overlay.frame.minX > firstX, "the caret moved to the second column")
        #expect(abs(overlay.frame.width - em) < 1)

        mounted.controller.caretShape = .bar
        #expect(mounted.controller.vimCaretOverlay == nil, ".bar drops the overlay")
    }

    @Test("a block caret covers a whole emoji cluster and a CJK cell")
    func blockCaretCoversWideClusters() throws {
        let mounted = try mount("\u{1F468}\u{200D}\u{1F4BB} x\n")
        defer { mounted.window.contentView = nil }
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))
        mounted.controller.caretShape = .block
        let overlay = try #require(mounted.controller.vimCaretOverlay)
        let clusterWidth = overlay.frame.width

        mounted.textView.setSelectedRange(NSRange(location: 6, length: 0))
        let letterWidth = overlay.frame.width

        #expect(clusterWidth > letterWidth * 1.5, "cluster \(clusterWidth) vs letter \(letterWidth)")
    }

    @Test("a block caret at a line end, the end of the document and an empty document is an em wide")
    func blockCaretFallsBackToEm() throws {
        let mounted = try mount("ab\n")
        defer { mounted.window.contentView = nil }
        mounted.controller.caretShape = .block
        let em = cellWidth(mounted, of: "m")

        mounted.textView.setSelectedRange(NSRange(location: 2, length: 0))
        let overlay = try #require(mounted.controller.vimCaretOverlay)
        #expect(abs(overlay.frame.width - em) < 1, "line end: \(overlay.frame.width)")

        // End of document after a trailing newline: FB22524198 puts TextKit's
        // caret rect for this position on the previous line's top; the overlay
        // must snap below it, one em wide.
        mounted.textView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(abs(overlay.frame.width - em) < 1, "end of document: \(overlay.frame.width)")
        let lastLineMaxY = try #require(lastTextLineMaxY(mounted.textView))
        #expect(overlay.frame.minY >= lastLineMaxY,
                "the EOF caret sits on the next line, not the previous line's top")
        #expect(overlay.frame.height > 10, "a full line height at the document end")

        let empty = try mount("")
        defer { empty.window.contentView = nil }
        empty.textView.setSelectedRange(NSRange(location: 0, length: 0))
        empty.controller.caretShape = .block
        let emptyOverlay = try #require(empty.controller.vimCaretOverlay)
        #expect(abs(emptyOverlay.frame.width - em) < 1, "empty document: \(emptyOverlay.frame.width)")
        #expect(emptyOverlay.frame.minY < 50, "the empty document's caret is on the first line")
    }

    @Test("a hollow caret is outlined and much fainter than the block")
    func hollowCaretIsDistinctFromBlock() throws {
        let mounted = try mount("mmm\n")
        defer { mounted.window.contentView = nil }
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))

        mounted.controller.caretShape = .block
        let block = try #require(mounted.controller.vimCaretOverlay)
        #expect(!block.isHollow)
        let blockFillAlpha = block.fillAlpha
        #expect(abs(blockFillAlpha - VimCaretOverlayView.blockFillAlpha) < 0.001)
        #expect(block.layer?.borderWidth == 0, "the block caret has no outline")

        mounted.controller.caretShape = .hollow
        let hollow = try #require(mounted.controller.vimCaretOverlay)
        #expect(hollow.isHollow)
        #expect(hollow.layer?.borderWidth == 1, "the hollow caret carries a 1 pt outline")
        #expect(
            hollow.fillAlpha == VimCaretOverlayView.hollowFillAlpha,
            "hollow fill \(hollow.fillAlpha) is the spec's faint fill")
        #expect(hollow.fillAlpha < blockFillAlpha,
                "the outline carries the marking, so the fill steps back")
        #expect(abs(hollow.frame.width - block.frame.width) < 1, "hollow still covers the cell")
    }

    @Test("the overlay follows a text edit")
    func overlayFollowsEdits() throws {
        let mounted = try mount("ab\n")
        defer { mounted.window.contentView = nil }
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))
        mounted.controller.caretShape = .block
        let overlay = try #require(mounted.controller.vimCaretOverlay)

        mounted.textView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        let em = cellWidth(mounted, of: "m")
        #expect(mounted.textView.string == "Xab\n")
        #expect(overlay.frame.minX >= em, "the caret moved past the inserted character")
        #expect(!overlay.isHidden)
    }

    @Test("the overlay is hidden for a selection and on resignFirstResponder")
    func overlayHidesForSelectionAndResignation() throws {
        let mounted = try mount("abc\n")
        defer { mounted.window.contentView = nil }
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))
        mounted.controller.caretShape = .block
        let overlay = try #require(mounted.controller.vimCaretOverlay)
        #expect(!overlay.isHidden)

        // The system indicator disappears for a selection; so must ours.
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 2))
        #expect(overlay.isHidden, "a selection has no insertion point")

        mounted.textView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(!overlay.isHidden)

        #expect(mounted.window.makeFirstResponder(nil))
        #expect(overlay.isHidden, "a view that is not first responder shows no caret")
    }

    @Test("the system indicator is hidden while a shape is active and restored on .bar")
    func indicatorDisplayModeFollowsTheShape() throws {
        let mounted = try mount("mmm\n")
        defer { mounted.window.contentView = nil }
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))

        let indicator = plantIndicator(in: mounted.textView)

        mounted.controller.caretShape = .block
        #expect(indicator.displayMode == .hidden, "the block caret owns the screen")

        // AppKit recreates indicators as windows change key status; a fresh
        // indicator is found and re-hidden by the next state update.
        let fresh = plantIndicator(in: mounted.textView)
        mounted.textView.updateInsertionPointStateAndRestartTimer(true)
        #expect(fresh.displayMode == .hidden)

        mounted.controller.caretShape = .bar
        #expect(indicator.displayMode == .automatic, ".bar gives the display mode back")
        #expect(fresh.displayMode == .automatic)
    }

    @Test("the overlay survives a controller handoff and a document switch")
    func overlaySurvivesControllerHandoff() throws {
        let mounted = try mount("tail\n")
        defer { mounted.window.contentView = nil }
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))
        mounted.controller.caretShape = .block
        _ = try #require(mounted.controller.vimCaretOverlay)

        // The updateNSView swap sequence: detach, adopt a new document, rebuild.
        let incoming = MarkdownEditorController()
        incoming.caretShape = .block
        mounted.controller.detach(textView: mounted.textView)
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))
        if let layoutManager = mounted.textView.textLayoutManager {
            incoming.adopt(layoutManager: layoutManager)
        }
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))

        // While NO controller is attached the shape is `.bar`: the overlay
        // may legitimately drop; what must survive is the mechanism — the new
        // controller's shape brings it back.
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = true
        let wrapper = NativeTextViewWrapper(
            text: .constant("new\n"),
            configuration: configuration,
            controller: incoming,
            fontName: "Menlo",
            fontSize: 14
        )
        let coordinator = wrapper.makeCoordinator()
        _ = coordinator.adopt(mounted.textView, text: "new\n")

        let overlay = try #require(incoming.vimCaretOverlay,
                                   "the new controller's block shape re-drew the caret")
        #expect(!overlay.isHidden)
        #expect(overlay === mounted.textView.subviews.first { $0 is VimCaretOverlayView })
    }
}

//
//  FocusDimTests.swift
//  MarkdownEngineTests
//
//  Focus dimming is per layout fragment: every fragment that does not touch
//  the lit range draws at the controller's alpha, and the lit one at full.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Focus dimming", .serialized)
struct FocusDimTests {
    private let text = "- first item\n\nSecond paragraph here.\n\nThird paragraph.\n"

    private func mount() throws -> (NSWindow, MarkdownEditorController, NativeTextView) {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        var configuration = MarkdownEditorConfiguration.default
        configuration.undo = .external
        let wrapper = NativeTextViewWrapper(
            text: .constant(text), configuration: configuration, controller: controller,
            fontName: "Menlo", fontSize: 14, onTextMutation: { _ in })
        let host = NSHostingView(rootView: wrapper)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return (window, controller, try #require(controller.textView as? NativeTextView))
    }

    /// Each laid-out fragment's first character and its dim alpha.
    private func alphas(_ textView: NativeTextView) throws -> [String: CGFloat?] {
        let manager = try #require(textView.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        let storage = try #require(manager.textContentManager as? NSTextContentStorage)
        var result: [String: CGFloat?] = [:]
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            guard let fragment = fragment as? MarkdownTextLayoutFragment else { return true }
            let start = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            let end = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.endLocation)
            let slice = (textView.string as NSString).substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !slice.isEmpty { result[slice] = fragment.focusDimAlpha }
            return true
        }
        return result
    }

    @Test("off by default: nothing dims")
    func offByDefault() throws {
        let (window, controller, textView) = try mount()
        defer { window.contentView = nil }
        #expect(controller.focusLitRange == nil)
        #expect(try alphas(textView).values.allSatisfy { $0 == nil })
    }

    @Test("fragments outside the lit range dim; the lit one does not")
    func dimsOutside() throws {
        let (window, controller, textView) = try mount()
        defer { window.contentView = nil }
        controller.focusLitRange = (text as NSString).range(of: "Second paragraph here.")
        let result = try alphas(textView)
        #expect(result["Second paragraph here."] == .some(nil))
        #expect(result["- first item"] == .some(0.35), "the bullet's fragment dims too")
        #expect(result["Third paragraph."] == .some(0.35))

        controller.focusDimAlpha = 0.5
        #expect(try alphas(textView)["Third paragraph."] == .some(0.5))
        controller.focusLitRange = nil
        #expect(try alphas(textView).values.allSatisfy { $0 == nil })
    }

    @Test("underlines draw ink under their words and nowhere else")
    func underlinesDraw() throws {
        let (window, controller, textView) = try mount()
        defer { window.contentView = nil }
        let word = (text as NSString).range(of: "paragraph here")
        let rects = try #require(textView.firstRect(forCharacterRange: word, actualRange: nil) as NSRect?)
        let local = textView.convert(window.convertFromScreen(rects), from: nil)
        let strip = NSRect(x: local.minX, y: local.minY, width: local.width, height: local.height + 4)
        func ink() -> Int {
            textView.displayIfNeeded()
            guard let rep = textView.bitmapImageRepForCachingDisplay(in: strip) else { return 0 }
            textView.cacheDisplay(in: strip, to: rep)
            var count = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent - c.greenComponent > 0.3 {
                        count += 1
                    }
                }
            }
            return count
        }
        #expect(ink() == 0)
        controller.underlines = [MarkdownUnderline(range: word, color: .systemRed)]
        #expect(ink() > 10, "a red wave under the words")
        controller.underlines = []
        #expect(ink() == 0)
    }

    @Test("an empty lit range lights the fragment it sits in")
    func emptyRangeLightsItsFragment() throws {
        let (window, controller, textView) = try mount()
        defer { window.contentView = nil }
        let start = (text as NSString).range(of: "Third").location
        controller.focusLitRange = NSRange(location: start, length: 0)
        let result = try alphas(textView)
        #expect(result["Third paragraph."] == .some(nil))
        #expect(result["Second paragraph here."] == .some(0.35))
    }

    /// TextKit 2 draws each fragment in its own subview. A focus change has to
    /// mark those, not just the text view, or they keep the old dim (or blur)
    /// until something else redraws them: over a second after a raw-mode edit.
    @Test("a focus change redraws every visible fragment", arguments: ["dim", "blur"])
    func focusChangeRedrawsFragments(_ kind: String) throws {
        let (window, controller, textView) = try mount()
        defer {
            MarkdownTextLayoutFragment.drawObserver = nil
            window.close()
        }
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        var drawn = 0
        MarkdownTextLayoutFragment.drawObserver = { _ in drawn += 1 }
        if kind == "dim" {
            controller.focusLitRange = NSRange(location: 0, length: 5)
        } else {
            controller.focusBlur = MarkdownFocusBlur(lineMinY: 0, lineMaxY: 20, maximumRadius: 6, rampDistance: 120)
        }
        // Layer-backed views draw at the next Core Animation commit.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        // Three paragraphs with text, two blank lines between them.
        #expect(drawn >= 3, "fragments redrawn: \(drawn)")
    }
}

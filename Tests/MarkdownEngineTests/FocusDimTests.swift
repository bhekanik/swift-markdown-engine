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
}

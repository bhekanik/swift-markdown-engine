//
//  VerticalOffsetScrollingTests.swift
//  MarkdownEngineTests
//
//  `MarkdownEditorController.scroll(toVerticalOffset:)` is the safe path for
//  a host that already knows the clip origin it wants (vim `zz`/`<C-e>`).
//  Writing the clip view directly lost to an armed restore and could park
//  past the real content height.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Vertical offset scrolling", .serialized)
struct VerticalOffsetScrollingTests {
    private struct MountedEditor {
        let window: NSWindow
        let host: NSHostingView<NativeTextViewWrapper>
        let controller: MarkdownEditorController
        let textView: NSTextView
        let scrollView: NSScrollView
    }

    private func mount(text: String) throws -> MountedEditor {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let wrapper = NativeTextViewWrapper(
            text: .constant(text),
            controller: controller,
            fontName: "Helvetica",
            fontSize: 16
        )
        let host = NSHostingView(rootView: wrapper)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        let textView = try #require(controller.textView)
        let scrollView = try #require(textView.enclosingScrollView)
        return MountedEditor(
            window: window,
            host: host,
            controller: controller,
            textView: textView,
            scrollView: scrollView
        )
    }

    private func longDocument(lines: Int = 400) -> String {
        (0..<lines)
            .map { "Line \($0): alpha bravo charlie delta echo foxtrot" }
            .joined(separator: "\n") + "\n"
    }

    @Test("an offset past either end clamps to the real content range")
    func offsetClampsAtTopAndBottom() throws {
        let mounted = try mount(text: longDocument())
        defer { mounted.window.contentView = nil }
        let clipView = mounted.scrollView.contentView
        let top = -mounted.scrollView.contentInsets.top

        #expect(mounted.controller.scroll(toVerticalOffset: -4_000))
        #expect(abs(clipView.bounds.origin.y - top) < 1)
        #expect(abs(mounted.controller.verticalScrollOffset - clipView.bounds.origin.y) < 0.5)
        #expect(abs(mounted.controller.visibleHeight - clipView.bounds.height) < 0.5)

        #expect(mounted.controller.scroll(toVerticalOffset: 1_000_000))
        let bottom = clipView.bounds.origin.y
        #expect(bottom > top + clipView.bounds.height)
        #expect(mounted.controller.scroll(toVerticalOffset: bottom + 800))
        #expect(abs(clipView.bounds.origin.y - bottom) < 1)
    }

    @Test("a scroll to the current offset does nothing")
    func unchangedOffsetIsANoOp() throws {
        let mounted = try mount(text: longDocument())
        defer { mounted.window.contentView = nil }
        let clipView = mounted.scrollView.contentView
        #expect(mounted.controller.scroll(toVerticalOffset: 480))
        let parked = clipView.bounds.origin.y
        #expect(parked > 0)

        let clamped = try #require(mounted.scrollView as? ClampedScrollView)
        clamped.armScrollRestore(to: 900)

        #expect(mounted.controller.scroll(toVerticalOffset: parked))
        #expect(abs(clipView.bounds.origin.y - parked) < 0.5)

        mounted.scrollView.needsLayout = true
        mounted.scrollView.layoutSubtreeIfNeeded()
        #expect(
            abs(clipView.bounds.origin.y - 900) < 1,
            "a no-op must leave an armed restore alone, got \(clipView.bounds.origin.y)"
        )
    }

    @Test("scrolling cancels an armed restore so a later layout cannot yank back")
    func scrollingCancelsArmedRestore() throws {
        let mounted = try mount(text: longDocument())
        defer { mounted.window.contentView = nil }
        let clipView = mounted.scrollView.contentView
        #expect(mounted.controller.scroll(toVerticalOffset: 200))
        let clamped = try #require(mounted.scrollView as? ClampedScrollView)
        clamped.armScrollRestore(to: 900)

        #expect(mounted.controller.scroll(toVerticalOffset: 360))
        let afterScroll = clipView.bounds.origin.y
        #expect(abs(afterScroll - 360) < 2)

        mounted.scrollView.needsLayout = true
        mounted.scrollView.layoutSubtreeIfNeeded()
        #expect(
            abs(clipView.bounds.origin.y - afterScroll) < 1,
            "restore replayed \(clipView.bounds.origin.y) over \(afterScroll)"
        )
    }

    @Test("a detached controller refuses a vertical offset scroll")
    func detachedControllerRefuses() throws {
        let mounted = try mount(text: "alpha\n")
        defer { mounted.window.contentView = nil }
        mounted.controller.detach(textView: mounted.textView)
        #expect(!mounted.controller.scroll(toVerticalOffset: 40))
        #expect(mounted.controller.verticalScrollOffset == 0)
        #expect(mounted.controller.visibleHeight == 0)
    }
}

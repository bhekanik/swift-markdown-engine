//
//  RangeScrollingTests.swift
//  MarkdownEngineTests
//


import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("TextKit 2 range scrolling", .serialized)
struct RangeScrollingTests {
    private nonisolated final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func read() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

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

    private func lineRect(at offset: Int, in textView: NSTextView) throws -> CGRect {
        let layoutManager = try #require(textView.textLayoutManager)
        let contentManager = try #require(layoutManager.textContentManager)
        let location = try #require(contentManager.location(
            layoutManager.documentRange.location,
            offsetBy: offset
        ))
        var result: CGRect?
        layoutManager.enumerateTextSegments(
            in: NSTextRange(location: location),
            type: .standard,
            options: []
        ) { _, frame, _, _ in
            result = frame
            return false
        }
        return try #require(result).offsetBy(
            dx: textView.textContainerOrigin.x,
            dy: textView.textContainerOrigin.y
        )
    }

    @Test("distant and centered reveals stay on TextKit 2")
    func scrollsThroughLayoutFragments() throws {
        let lines = (0..<1_200).map { "Line \($0): alpha bravo charlie delta" }
        let text = lines.joined(separator: "\n") + "\n"
        let mounted = try mount(text: text)
        defer { mounted.window.contentView = nil }

        let compatibilitySwitches = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification,
            object: mounted.textView,
            queue: nil
        ) { _ in
            compatibilitySwitches.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let clipView = mounted.scrollView.contentView
        let startY = clipView.bounds.minY
        let end = (text as NSString).length
        #expect(mounted.controller.scroll(range: NSRange(location: end, length: 0)))
        #expect(clipView.bounds.minY > startY + clipView.bounds.height)

        let middleNeedle = "Line 600:"
        let middleRange = (text as NSString).range(of: middleNeedle)
        let nativeTextView = try #require(mounted.textView as? NativeTextView)
        nativeTextView.suppressAutoRevealOnce = true
        #expect(mounted.controller.scroll(range: middleRange, position: .center))
        #expect(nativeTextView.suppressAutoRevealOnce,
                "an explicit host scroll consumed AppKit's auto-reveal suppression")

        let line = try lineRect(at: middleRange.location, in: mounted.textView)
            .offsetBy(dx: mounted.textView.frame.minX, dy: mounted.textView.frame.minY)
        let viewportCenter = clipView.bounds.midY
        #expect(abs(line.midY - viewportCenter) < 2)
        #expect(compatibilitySwitches.read() == 0)
    }

    @Test("nearest reveals an entire multiline range that fits the viewport")
    func revealsFittingMultilineRange() throws {
        let text = (0..<100)
            .map { "Line \($0): alpha bravo charlie delta" }
            .joined(separator: "\n") + "\n"
        let mounted = try mount(text: text)
        defer { mounted.window.contentView = nil }

        let ns = text as NSString
        let start = ns.range(of: "Line 10:").location
        let end = NSMaxRange(ns.range(of: "Line 21:"))
        let range = NSRange(location: start, length: end - start)
        let clipView = mounted.scrollView.contentView
        let beforeY = clipView.bounds.minY

        #expect(mounted.controller.scroll(range: range, position: .nearest))
        #expect(clipView.bounds.minY > beforeY)

        let firstLine = try lineRect(at: start, in: mounted.textView)
            .offsetBy(dx: mounted.textView.frame.minX, dy: mounted.textView.frame.minY)
        let lastLine = try lineRect(at: end - 1, in: mounted.textView)
            .offsetBy(dx: mounted.textView.frame.minX, dy: mounted.textView.frame.minY)
        let visibleTop = clipView.bounds.minY + mounted.scrollView.contentInsets.top
        let visibleBottom = clipView.bounds.maxY - mounted.scrollView.contentInsets.bottom
        #expect(firstLine.minY >= visibleTop - 0.5)
        #expect(lastLine.maxY <= visibleBottom + 0.5)

        #expect(mounted.controller.scroll(range: range, position: .center))
        #expect(abs(firstLine.union(lastLine).midY - clipView.bounds.midY) < 2)
    }

    @Test("nearest keeps an intersecting oversized range stable")
    func oversizedRangeDoesNotOscillate() throws {
        let text = (0..<100)
            .map { "Line \($0): alpha bravo charlie delta" }
            .joined(separator: "\n") + "\n"
        let mounted = try mount(text: text)
        defer { mounted.window.contentView = nil }

        let ns = text as NSString
        let start = ns.range(of: "Line 30:").location
        let end = NSMaxRange(ns.range(of: "Line 90:"))
        let range = NSRange(location: start, length: end - start)
        let clipView = mounted.scrollView.contentView

        #expect(mounted.controller.scroll(range: range, position: .nearest))
        let firstY = clipView.bounds.minY
        #expect(firstY > 0)
        #expect(mounted.controller.scroll(range: range, position: .nearest))
        #expect(abs(clipView.bounds.minY - firstY) < 0.5)
    }

    @Test("detached and invalid ranges are refused")
    func refusesRangesItCannotScroll() throws {
        let mounted = try mount(text: "alpha\n")
        defer { mounted.window.contentView = nil }

        #expect(!mounted.controller.scroll(range: NSRange(location: NSNotFound, length: 0)))
        #expect(!mounted.controller.scroll(range: NSRange(location: 7, length: 0)))

        mounted.controller.detach(textView: mounted.textView)
        #expect(!mounted.controller.scroll(range: NSRange(location: 0, length: 0)))
    }
}

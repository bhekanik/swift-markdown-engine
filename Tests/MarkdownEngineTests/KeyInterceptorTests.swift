//
//  KeyInterceptorTests.swift
//  MarkdownEngineTests
//
//  The keyboard seam a modal key layer (vim) hangs off: `keyDown`,
//  `insertText(_:replacementRange:)` and `doCommand(by:)` consult
//  `MarkdownEditorController.keyInterceptor` first, never while marked text is
//  up, and leave the input path untouched when nothing is installed.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Key interceptor", .serialized)
struct KeyInterceptorTests {
    private final class RecordingInterceptor: MarkdownKeyInterceptor {
        var keyDowns: [String] = []
        var insertions: [String] = []
        var commands: [Selector] = []
        var consumesKeyDown: (String) -> Bool = { _ in false }
        var consumesInsertText: (String) -> Bool = { _ in false }
        var consumesCommand: (Selector) -> Bool = { _ in false }

        func interceptKeyDown(_ event: NSEvent, in textView: NSTextView) -> Bool {
            let characters = event.charactersIgnoringModifiers ?? ""
            keyDowns.append(characters)
            return consumesKeyDown(characters)
        }

        func interceptInsertText(_ text: String, replacementRange: NSRange, in textView: NSTextView) -> Bool {
            insertions.append(text)
            return consumesInsertText(text)
        }

        func interceptCommand(_ selector: Selector, in textView: NSTextView) -> Bool {
            commands.append(selector)
            return consumesCommand(selector)
        }
    }

    private struct Mounted {
        let window: NSWindow
        let controller: MarkdownEditorController
        let textView: NativeTextView
        let mutations: Mutations
    }

    private final class Mutations {
        var received: [MarkdownTextMutation] = []
    }

    private func mount(_ text: String, rawSourceMode: Bool = true) throws -> Mounted {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let mutations = Mutations()
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = rawSourceMode
        configuration.undo = .external
        let wrapper = NativeTextViewWrapper(
            text: .constant(text),
            configuration: configuration,
            controller: controller,
            fontName: "Menlo",
            fontSize: 14,
            onTextMutation: { mutations.received.append($0) }
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
        window.makeFirstResponder(textView)
        return Mounted(window: window, controller: controller, textView: textView, mutations: mutations)
    }

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    @Test("a consumed keyDown never reaches the input system")
    func consumedKeyDownStopsThere() throws {
        let mounted = try mount("abc\n")
        defer { mounted.window.contentView = nil }
        let interceptor = RecordingInterceptor()
        interceptor.consumesKeyDown = { $0 == "x" }
        mounted.controller.keyInterceptor = interceptor
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))

        mounted.textView.keyDown(with: key("x"))

        #expect(interceptor.keyDowns == ["x"])
        #expect(interceptor.insertions.isEmpty)
        #expect(mounted.textView.string == "abc\n")
        #expect(mounted.mutations.received.isEmpty)
    }

    @Test("a declined keyDown goes through interpretKeyEvents and back as insertText")
    func declinedKeyDownReachesInsertText() throws {
        let mounted = try mount("abc\n")
        defer { mounted.window.contentView = nil }
        let interceptor = RecordingInterceptor()
        mounted.controller.keyInterceptor = interceptor
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))

        mounted.textView.keyDown(with: key("x"))

        #expect(interceptor.keyDowns == ["x"])
        #expect(interceptor.insertions == ["x"])
        #expect(mounted.textView.string == "xabc\n")
    }

    @Test("a consumed insertText mutates nothing")
    func consumedInsertTextMutatesNothing() throws {
        let mounted = try mount("abc\n")
        defer { mounted.window.contentView = nil }
        let interceptor = RecordingInterceptor()
        interceptor.consumesInsertText = { _ in true }
        mounted.controller.keyInterceptor = interceptor
        mounted.textView.setSelectedRange(NSRange(location: 1, length: 0))

        mounted.textView.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        mounted.textView.keyDown(with: key("y"))

        #expect(interceptor.insertions == ["Z", "y"])
        #expect(mounted.textView.string == "abc\n")
        #expect(mounted.mutations.received.isEmpty)
    }

    @Test("a consumed command selector runs nothing")
    func consumedCommandRunsNothing() throws {
        let mounted = try mount("abc\n")
        defer { mounted.window.contentView = nil }
        let interceptor = RecordingInterceptor()
        interceptor.consumesCommand = { $0 == #selector(NSResponder.deleteBackward(_:)) }
        mounted.controller.keyInterceptor = interceptor
        mounted.textView.setSelectedRange(NSRange(location: 2, length: 0))

        mounted.textView.keyDown(with: key("\u{7F}"))

        #expect(interceptor.commands.contains(#selector(NSResponder.deleteBackward(_:))))
        #expect(mounted.textView.string == "abc\n")
    }

    @Test("the interceptor is skipped while marked text is up")
    func compositionBypassesInterceptor() throws {
        let mounted = try mount("abc\n")
        defer { mounted.window.contentView = nil }
        let interceptor = RecordingInterceptor()
        interceptor.consumesKeyDown = { _ in true }
        interceptor.consumesInsertText = { _ in true }
        mounted.controller.keyInterceptor = interceptor
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))
        mounted.textView.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(mounted.textView.hasMarkedText())

        // An input method replacing its own marked run.
        mounted.textView.insertText("\u{65E5}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interceptor.insertions.isEmpty)
        #expect(mounted.textView.string == "\u{65E5}abc\n")

        mounted.textView.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(mounted.textView.hasMarkedText())
        mounted.textView.keyDown(with: key("n"))

        // Measured: with no input method attached, `NSTextInputContext` ends the
        // composition on the key by unmarking (which removes the run) and then
        // committing it through an ordinary `insertText("ni")`, followed by the
        // key's own `insertText("n")`. Both arrive with no marked text, so both
        // are the interceptor's to take — exactly the "committed text" path a
        // vim layer needs. The physical key itself never reached it.
        #expect(interceptor.keyDowns.isEmpty)
        #expect(interceptor.insertions == ["ni", "n"])
        #expect(!mounted.textView.hasMarkedText())
        #expect(mounted.textView.string == "\u{65E5}abc\n")
    }

    @Test("with no interceptor installed the input path is unchanged")
    func noInterceptorIsStockAppKit() throws {
        for raw in [true, false] {
            let mounted = try mount("abc\n", rawSourceMode: raw)
            defer { mounted.window.contentView = nil }
            #expect(mounted.controller.keyInterceptor == nil)
            mounted.textView.setSelectedRange(NSRange(location: 3, length: 0))

            mounted.textView.keyDown(with: key("x"))
            mounted.textView.keyDown(with: key("\u{7F}"))
            mounted.textView.keyDown(with: key("y"))

            #expect(mounted.textView.string == "abcy\n")
            #expect(mounted.mutations.received.count == 3)
        }
    }

    @Test("a detached interceptor stops being consulted")
    func weakInterceptorIsReleased() throws {
        let mounted = try mount("abc\n")
        defer { mounted.window.contentView = nil }
        var interceptor: RecordingInterceptor? = RecordingInterceptor()
        interceptor?.consumesKeyDown = { _ in true }
        mounted.controller.keyInterceptor = interceptor
        interceptor = nil
        #expect(mounted.controller.keyInterceptor == nil)
        mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))

        mounted.textView.keyDown(with: key("x"))

        #expect(mounted.textView.string == "xabc\n")
    }

}

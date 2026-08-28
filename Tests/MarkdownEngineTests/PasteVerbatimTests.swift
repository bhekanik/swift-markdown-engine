//
//  PasteVerbatimTests.swift
//  MarkdownEngineTests
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Verbatim paste paths", .serialized)
struct PasteVerbatimTests {
    private let source = "    let x = 1\n\n\nline  \n"

    private func textView(rawSourceMode: Bool) -> NativeTextView {
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        textView.configuration.rawSourceMode = rawSourceMode
        return textView
    }

    private func expectBytesEqual(_ actual: String, _ expected: String) {
        #expect(Data(actual.utf8) == Data(expected.utf8))
    }

    @Test("the private Markdown flavor is byte-exact in rich mode")
    func privateMarkdownIsVerbatimInRichMode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(source, forType: MarkdownPasteboardWriter.markdownType)
        defer { pasteboard.clearContents() }

        let textView = textView(rawSourceMode: false)
        textView.paste(nil)

        expectBytesEqual(textView.string, source)
    }

    @Test("plain text is byte-exact in raw mode")
    func plainTextIsVerbatimInRawMode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(source, forType: .string)
        defer { pasteboard.clearContents() }

        let textView = textView(rawSourceMode: true)
        textView.paste(nil)

        expectBytesEqual(textView.string, source)
    }

    @Test("a text file is byte-exact in raw mode")
    func textFileIsVerbatimInRawMode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        defer { pasteboard.clearContents() }

        let textView = textView(rawSourceMode: true)
        textView.paste(nil)

        expectBytesEqual(textView.string, source)
    }

    @Test("foreign plain text still gets rich-mode cleanup")
    func foreignPlainTextStillGetsRichCleanup() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(source, forType: .string)
        defer { pasteboard.clearContents() }

        let textView = textView(rawSourceMode: false)
        textView.paste(nil)

        #expect(textView.string == "let x = 1\n\nline")
    }
}

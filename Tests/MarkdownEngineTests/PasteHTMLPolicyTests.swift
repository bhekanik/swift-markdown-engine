//
//  PasteHTMLPolicyTests.swift
//  MarkdownEngineTests
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Pasted HTML policy", .serialized)
struct PasteHTMLPolicyTests {
    private let html = "<h2>Plan</h2><ul><li>one</li><li><b>two</b></li></ul>"
    private let plain = "Plan\none\ntwo"

    private func paste(convertingHTML: Bool) -> String {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(html, forType: .html)
        pasteboard.setString(plain, forType: .string)
        defer { pasteboard.clearContents() }

        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isEditable = true
        textView.configuration.convertsPastedHTML = convertingHTML
        textView.paste(nil)
        return textView.string
    }

    @Test("converting is the default")
    func defaultConverts() {
        #expect(MarkdownEditorConfiguration.default.convertsPastedHTML)
    }

    @Test("on: structured HTML becomes Markdown")
    func convertsWhenOn() {
        let result = paste(convertingHTML: true)
        #expect(result.contains("## Plan"))
        #expect(result.contains("**two**"))
    }

    @Test("off: the plain-text flavor is pasted instead")
    func plainWhenOff() {
        let result = paste(convertingHTML: false)
        #expect(!result.contains("##"))
        #expect(!result.contains("**"))
        #expect(result.contains("Plan"))
        #expect(result.contains("two"))
    }
}

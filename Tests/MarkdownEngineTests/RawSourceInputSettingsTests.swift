//
//  RawSourceInputSettingsTests.swift
//  MarkdownEngineTests
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Raw source input settings")
struct RawSourceInputSettingsTests {
    private struct InputSettings: Equatable {
        let quoteSubstitution: Bool
        let dashSubstitution: Bool
        let textReplacement: Bool
        let spellingCorrection: Bool
        let smartInsertDelete: Bool

        init(_ textView: NSTextView) {
            quoteSubstitution = textView.isAutomaticQuoteSubstitutionEnabled
            dashSubstitution = textView.isAutomaticDashSubstitutionEnabled
            textReplacement = textView.isAutomaticTextReplacementEnabled
            spellingCorrection = textView.isAutomaticSpellingCorrectionEnabled
            smartInsertDelete = textView.smartInsertDeleteEnabled
        }

        static let disabled = InputSettings(
            quoteSubstitution: false,
            dashSubstitution: false,
            textReplacement: false,
            spellingCorrection: false,
            smartInsertDelete: false
        )

        private init(
            quoteSubstitution: Bool,
            dashSubstitution: Bool,
            textReplacement: Bool,
            spellingCorrection: Bool,
            smartInsertDelete: Bool
        ) {
            self.quoteSubstitution = quoteSubstitution
            self.dashSubstitution = dashSubstitution
            self.textReplacement = textReplacement
            self.spellingCorrection = spellingCorrection
            self.smartInsertDelete = smartInsertDelete
        }
    }

    private func wrapper(rawSourceMode: Bool) -> NativeTextViewWrapper {
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = rawSourceMode
        return NativeTextViewWrapper(
            text: .constant("plain text\n"),
            configuration: configuration,
            fontName: "Helvetica",
            fontSize: 16
        )
    }

    private func mountedHost(
        rawSourceMode: Bool
    ) throws -> (NSHostingView<NativeTextViewWrapper>, NativeTextView) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: wrapper(rawSourceMode: rawSourceMode))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        return (host, try #require(findTextView(in: host)))
    }

    private func findTextView(in view: NSView) -> NativeTextView? {
        if let textView = view as? NativeTextView {
            return textView
        }
        return view.subviews.lazy.compactMap(findTextView).first
    }

    @Test("a raw mount disables every AppKit source rewrite")
    func rawMountDisablesSourceRewrites() throws {
        let (_, textView) = try mountedHost(rawSourceMode: true)

        #expect(InputSettings(textView) == .disabled)
    }

    @Test("a rich to raw to rich switch restores every live input setting")
    func rawModeRoundTripRestoresLiveSettings() throws {
        let (host, textView) = try mountedHost(rawSourceMode: false)
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.smartInsertDeleteEnabled = true
        let beforeRaw = InputSettings(textView)

        host.rootView = wrapper(rawSourceMode: true)
        host.layoutSubtreeIfNeeded()

        let rawTextView = try #require(findTextView(in: host))
        #expect(rawTextView === textView)
        #expect(InputSettings(rawTextView) == .disabled)

        host.rootView = wrapper(rawSourceMode: false)
        host.layoutSubtreeIfNeeded()

        let richTextView = try #require(findTextView(in: host))
        #expect(richTextView === textView)
        #expect(InputSettings(richTextView) == beforeRaw)
    }
}

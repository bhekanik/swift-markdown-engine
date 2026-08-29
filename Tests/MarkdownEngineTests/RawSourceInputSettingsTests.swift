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

    private func wrapper(
        rawSourceMode: Bool,
        text: String = "plain text\n",
        spellChecking: SpellCheckingPolicy = .default
    ) -> NativeTextViewWrapper {
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = rawSourceMode
        configuration.spellChecking = spellChecking
        return NativeTextViewWrapper(
            text: .constant(text),
            configuration: configuration,
            fontName: "Helvetica",
            fontSize: 16
        )
    }

    private func mountedHost(
        rawSourceMode: Bool,
        text: String = "plain text\n",
        spellChecking: SpellCheckingPolicy = .default
    ) throws -> (NSHostingView<NativeTextViewWrapper>, NativeTextView) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: wrapper(
            rawSourceMode: rawSourceMode,
            text: text,
            spellChecking: spellChecking
        ))
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

    @Test("leaving raw mode with the caret in fenced code reapplies code settings")
    func leavingRawInsideFencedCodeReappliesContext() throws {
        let text = "prose\n```\nmisspeled code\n```"
        let (host, textView) = try mountedHost(rawSourceMode: false, text: text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        host.rootView = wrapper(rawSourceMode: true, text: text)
        host.layoutSubtreeIfNeeded()
        let codeLocation = (text as NSString).length
        textView.setSelectedRange(NSRange(location: codeLocation, length: 0))
        host.rootView = wrapper(rawSourceMode: false, text: text)
        host.layoutSubtreeIfNeeded()

        #expect(textView.selectedRange() == NSRange(location: codeLocation, length: 0))
        #expect(textView.isContinuousSpellCheckingEnabled == false)
        #expect(textView.isGrammarCheckingEnabled == false)
        #expect(textView.isAutomaticSpellingCorrectionEnabled == false)
        #expect(textView.isAutomaticQuoteSubstitutionEnabled == false)
    }

    @Test("leaving raw mode with the caret in a link reapplies link settings")
    func leavingRawInsideLinkReappliesContext() {
        let text = "prose [misspeled](https://example.com) tail\n"
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text),
            fontName: "Helvetica",
            fontSize: 16
        )
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400)
        )
        textView.isEditable = true
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        coordinator.enterRawSourceMode(textView)
        coordinator.configuration.rawSourceMode = false
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        let linkLocation = (text as NSString).range(of: "misspeled").location
        textView.setSelectedRange(NSRange(location: linkLocation, length: 0))
        coordinator.leaveRawSourceMode(textView)

        #expect(textView.selectedRange() == NSRange(location: linkLocation, length: 0))
        #expect(textView.isContinuousSpellCheckingEnabled == false)
        #expect(textView.isGrammarCheckingEnabled == false)
        #expect(textView.isAutomaticSpellingCorrectionEnabled == false)
        #expect(textView.isAutomaticQuoteSubstitutionEnabled == false)
    }

    @Test("leaving raw mode in prose restores preferences including off values")
    func leavingRawInProseRestoresExactPreferences() throws {
        let policy = SpellCheckingPolicy(
            continuousSpellChecking: false,
            grammarChecking: false,
            automaticSpellingCorrection: false
        )
        let (host, textView) = try mountedHost(
            rawSourceMode: false,
            spellChecking: policy
        )
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = true
        let beforeRaw = InputSettings(textView)

        host.rootView = wrapper(
            rawSourceMode: true,
            spellChecking: policy
        )
        host.layoutSubtreeIfNeeded()
        host.rootView = wrapper(
            rawSourceMode: false,
            spellChecking: policy
        )
        host.layoutSubtreeIfNeeded()

        #expect(InputSettings(textView) == beforeRaw)
        #expect(textView.isContinuousSpellCheckingEnabled == false)
        #expect(textView.isGrammarCheckingEnabled == false)
        #expect(textView.isAutomaticSpellingCorrectionEnabled == false)
    }
}

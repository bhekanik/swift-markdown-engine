//
//  AccessibilityTests.swift
//  MarkdownEngineTests
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Visible Markdown accessibility", .serialized)
struct AccessibilityTests {
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
        let controller: MarkdownEditorController
        let textView: NativeTextView
    }

    private func view(
        text: String,
        configuration: MarkdownEditorConfiguration = .default
    ) -> NativeTextView {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.textContainer = container
        controller.textContentStorage.addTextLayoutManager(layoutManager)
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            textContainer: container
        )
        textView.isEditable = true
        let coordinator = NativeTextViewWrapper(
            text: .constant(text),
            configuration: configuration,
            controller: controller,
            fontName: "Helvetica",
            fontSize: 16
        ).makeCoordinator()
        coordinator.adopt(textView, text: text)
        return textView
    }

    private func mountedView(text: String) throws -> MountedEditor {
        let controller = MarkdownEditorController()
        let host = NSHostingView(rootView: NativeTextViewWrapper(
            text: .constant(text),
            controller: controller,
            fontName: "Helvetica",
            fontSize: 16
        ))
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
        let textView = try #require(controller.textView as? NativeTextView)
        return MountedEditor(
            window: window,
            controller: controller,
            textView: textView
        )
    }

    @Test("visible text and selection hide Markdown syntax")
    func visibleTextAndSelection() throws {
        let source = "# Alpha [bravo](https://secret.example) 👩🏽‍💻\n"
        let textView = view(text: source)
        let visible = "Alpha bravo 👩🏽‍💻\n"

        #expect(textView.accessibilityNumberOfCharacters() == (visible as NSString).length)
        #expect(textView.accessibilityString(
            for: NSRange(location: 0, length: (visible as NSString).length)
        ) == visible)
        #expect(textView.accessibilityString(
            for: NSRange(location: 0, length: Int.max)
        ) == nil)

        let sourceBravo = (source as NSString).range(of: "bravo")
        let visibleBravo = (visible as NSString).range(of: "bravo")
        textView.setSelectedRange(sourceBravo)
        #expect(textView.accessibilitySelectedTextRange() == visibleBravo)
        #expect(textView.accessibilitySelectedText() == "bravo")

        let visibleAlpha = (visible as NSString).range(of: "Alpha")
        textView.setAccessibilitySelectedTextRange(visibleAlpha)
        #expect(textView.selectedRange() == (source as NSString).range(of: "Alpha"))

        let emoji = (visible as NSString).range(of: "👩🏽‍💻")
        #expect(textView.accessibilityRange(for: emoji.location) == emoji)
    }

    @Test("all inherited text surfaces use visible text and coordinates")
    func inheritedTextSurfacesUseProjection() throws {
        let source = "---\ntitle: Hidden\n---\n# Alpha [bravo](https://secret.example)\n"
        let visible = "Alpha bravo\n"
        let textView = view(text: source)
        let sourceBravo = (source as NSString).range(of: "bravo")
        let visibleBravo = (visible as NSString).range(of: "bravo")
        textView.selectedRanges = [NSValue(range: sourceBravo)]

        #expect(textView.accessibilityValue() == visible)
        #expect(textView.accessibilitySelectedTextRanges() == [NSValue(range: visibleBravo)])
        #expect(textView.accessibilityInsertionPointLineNumber() == 0)

        let rtf = try #require(textView.accessibilityRTF(
            for: NSRange(location: 0, length: 5)
        ))
        let decoded = try NSAttributedString(
            data: rtf,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        #expect(decoded.string == "Alpha")

        let styleRange = textView.accessibilityStyleRange(for: visibleBravo.location)
        #expect(styleRange.location != NSNotFound)
        #expect(NSMaxRange(styleRange) <= (visible as NSString).length)

        textView.setAccessibilitySelectedTextRanges([NSValue(
            range: (visible as NSString).range(of: "Alpha")
        )])
        #expect(textView.selectedRange() == (source as NSString).range(of: "Alpha"))
    }

    @Test("visible character range follows the TextKit 2 viewport")
    func visibleCharacterRangeTracksViewport() throws {
        let text = (0..<1_200)
            .map { "Line \($0): alpha bravo charlie delta" }
            .joined(separator: "\n") + "\n"
        let mounted = try mountedView(text: text)
        defer { mounted.window.contentView = nil }
        let compatibilitySwitches = LockedCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification,
            object: mounted.textView,
            queue: nil
        ) { _ in compatibilitySwitches.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        let fullLength = (text as NSString).length
        let top = mounted.textView.accessibilityVisibleCharacterRange()
        #expect(top.location == 0)
        #expect(top.length > 0 && top.length < fullLength / 4)

        let middleSource = (text as NSString).range(of: "Line 600:")
        #expect(mounted.controller.scroll(range: middleSource, position: .center))
        let middle = mounted.textView.accessibilityVisibleCharacterRange()
        #expect(middle.location > top.location)
        #expect(middle.length > 0 && middle.length < fullLength / 4)

        #expect(mounted.controller.scroll(range: NSRange(location: fullLength, length: 0)))
        let bottom = mounted.textView.accessibilityVisibleCharacterRange()
        #expect(bottom.location > middle.location)
        #expect(NSMaxRange(bottom) == fullLength)
        #expect(compatibilitySwitches.read() == 0)
    }

    @Test("caret frames use projected TextKit 2 insertion points")
    func projectedCaretFrames() throws {
        let source = "# Alpha [bravo](https://secret.example)\n"
        let visible = "Alpha bravo\n"
        let mounted = try mountedView(text: source)
        defer { mounted.window.contentView = nil }

        let visibleNSString = visible as NSString
        let offsets = [
            0,
            visibleNSString.range(of: "bravo").location,
            visibleNSString.length,
        ]
        let frames = offsets.map { offset in
            mounted.textView.accessibilityFrame(
                for: NSRange(location: offset, length: 0)
            )
        }
        for frame in frames {
            #expect(frame.width == 0)
            #expect(frame.height > 0)
            #expect(frame != .zero)
        }
        let firstCharacter = mounted.textView.accessibilityFrame(
            for: NSRange(location: 0, length: 1)
        )
        #expect(firstCharacter.width > 0)
        #expect(frames[0].origin == firstCharacter.origin)
        #expect(abs(frames[2].minY - frames[0].minY) >= frames[0].height / 2)

        let unterminated = try mountedView(text: "# Alpha")
        defer { unterminated.window.contentView = nil }
        let unterminatedStart = unterminated.textView.accessibilityFrame(
            for: NSRange(location: 0, length: 0)
        )
        let unterminatedEnd = unterminated.textView.accessibilityFrame(
            for: NSRange(location: 5, length: 0)
        )
        #expect(abs(unterminatedEnd.minY - unterminatedStart.minY) < 1)
        #expect(unterminatedEnd.minX > unterminatedStart.minX)
        #expect(unterminatedEnd.width == 0 && unterminatedEnd.height > 0)

        #expect(mounted.textView.accessibilityFrame(
            for: NSRange(location: visibleNSString.length + 1, length: 0)
        ) == .zero)
        #expect(mounted.textView.accessibilityFrame(
            for: NSRange(location: NSNotFound, length: 0)
        ) == .zero)

        let detached = view(text: source)
        #expect(detached.accessibilityFrame(
            for: NSRange(location: 0, length: 0)
        ) == .zero)
    }

    @Test("attributed text carries heading, list, link, image and footnote semantics")
    func attributedStructure() throws {
        let source = """
        ## Heading [link](https://example.com)
        - task
        ![Alt](image.png)
        Note[^n].

        [^n]: Footnote body
        """
        let textView = view(text: source)
        let length = textView.accessibilityNumberOfCharacters()
        let attributed = try #require(textView.accessibilityAttributedString(
            for: NSRange(location: 0, length: length)
        ))
        let visible = attributed.string as NSString

        let heading = visible.range(of: "Heading")
        #expect(attributed.attribute(
            .accessibilityCustomText,
            at: heading.location,
            effectiveRange: nil
        ) as? [String] == ["Heading level 2"])

        let task = visible.range(of: "task")
        #expect((attributed.attribute(
            .accessibilityListItemPrefix,
            at: task.location,
            effectiveRange: nil
        ) as? NSAttributedString)?.string == "•")
        #expect(attributed.attribute(
            .accessibilityListItemLevel,
            at: task.location,
            effectiveRange: nil
        ) as? Int == 0)

        let link = visible.range(of: "link")
        #expect(attributed.attribute(
            .accessibilityLink,
            at: link.location,
            effectiveRange: nil
        ) != nil)

        let image = visible.range(of: "Alt")
        #expect(attributed.attribute(
            .accessibilityAttachment,
            at: image.location,
            effectiveRange: nil
        ) != nil)

        let footnote = visible.range(of: "Footnote body")
        #expect(attributed.attribute(
            .accessibilityCustomText,
            at: footnote.location,
            effectiveRange: nil
        ) as? [String] == ["Footnote: n"])
    }

    @Test("standard rotors navigate rendered structure")
    func rotorsNavigateVisibleRanges() throws {
        let source = "# First\n## Second [link](https://example.com) ![Alt](image.png)\n"
        let textView = view(text: source)
        let rotors = textView.accessibilityCustomRotors()
        let headingRotor = try #require(rotors.first { $0.type == .heading })
        let linkRotor = try #require(rotors.first { $0.type == .link })
        let imageRotor = try #require(rotors.first { $0.type == .image })

        let next = NSAccessibilityCustomRotor.SearchParameters()
        next.searchDirection = .next
        let firstHeading = try #require(textView.rotor(headingRotor, resultFor: next))
        #expect(firstHeading.customLabel == "First")

        next.currentItem = firstHeading
        let secondHeading = try #require(textView.rotor(headingRotor, resultFor: next))
        #expect(secondHeading.customLabel == "Second link Alt")

        let filtered = NSAccessibilityCustomRotor.SearchParameters()
        filtered.searchDirection = .next
        filtered.filterString = "LINK"
        let link = try #require(textView.rotor(linkRotor, resultFor: filtered))
        #expect(link.customLabel == "link")

        let image = try #require(textView.rotor(imageRotor, resultFor: next))
        #expect(image.customLabel == "Alt")
    }

    @Test("raw mode exposes source and no rendered-structure rotors")
    func rawMode() {
        let source = "# [Heading](https://example.com)\n"
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = true
        let textView = view(text: source, configuration: configuration)

        #expect(textView.accessibilityString(
            for: NSRange(location: 0, length: (source as NSString).length)
        ) == source)
        #expect(textView.accessibilityCustomRotors().isEmpty)
    }

    @Test("line lookup follows NSString line boundaries")
    func lineLookupSupportsDocumentSeparators() throws {
        let textView = view(text: "alpha\rbeta\u{2028}gamma")
        let visibleString = try #require(textView.accessibilityString(
            for: NSRange(location: 0, length: textView.accessibilityNumberOfCharacters())
        ))
        let visible = visibleString as NSString

        #expect(textView.accessibilityLine(for: visible.range(of: "alpha").location) == 0)
        #expect(textView.accessibilityLine(for: visible.range(of: "beta").location) == 1)
        #expect(textView.accessibilityLine(for: visible.range(of: "gamma").location) == 2)
        #expect(textView.accessibilityRange(forLine: 1) == visible.lineRange(
            for: NSRange(location: visible.range(of: "beta").location, length: 0)
        ))
    }

    @Test("EOF stays on unterminated lines and advances after a terminator")
    func lineLookupAtEOF() {
        let unterminated = view(text: "alpha")
        #expect(unterminated.accessibilityLine(for: 5) == 0)

        let terminated = view(text: "alpha\n")
        #expect(terminated.accessibilityLine(for: 6) == 1)
    }
}

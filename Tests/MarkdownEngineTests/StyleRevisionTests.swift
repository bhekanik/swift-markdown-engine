import AppKit
import Observation
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Mounted style revision", .serialized)
struct StyleRevisionTests {
    private final class Highlighter: SyntaxHighlighter, @unchecked Sendable {
        let color: NSColor
        var calls = 0

        init(color: NSColor) { self.color = color }

        func codeFont(size: CGFloat) -> NSFont {
            .monospacedSystemFont(ofSize: size, weight: .regular)
        }

        func backgroundColor() -> NSColor { .clear }

        func highlight(code: String, language: String?) -> NSAttributedString? {
            calls += 1
            return NSAttributedString(
                string: code,
                attributes: [.foregroundColor: color]
            )
        }

        var appearanceDidChangeNotification: Notification.Name? { nil }
    }

    @Observable
    final class Model {
        var text = "Plain prose.\n\n```swift\nlet answer = 42\n```\n"
        var configuration: MarkdownEditorConfiguration
        var revision = "red"

        init(configuration: MarkdownEditorConfiguration) {
            self.configuration = configuration
        }
    }

    private struct Host: View {
        let model: Model

        var body: some View {
            NativeTextViewWrapper(
                text: Binding(
                    get: { model.text },
                    set: { model.text = $0 }
                ),
                configuration: model.configuration,
                styleRevision: model.revision
            )
        }
    }

    @Test("unchanged text and font adopt the new theme and service")
    func mountedStyleRevisionRestyles() throws {
        let red = Highlighter(color: .systemRed)
        let blue = Highlighter(color: .systemBlue)
        let model = Model(configuration: configuration(red, bodyText: .systemBrown))
        let host = NSHostingView(rootView: Host(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        settle(host)
        let textView = try #require(descendants(of: host).compactMap { $0 as? NSTextView }.first)
        let token = (textView.string as NSString).range(of: "answer").location
        let prose = (textView.string as NSString).range(of: "Plain").location
        #expect(textView.textStorage?.attribute(.foregroundColor, at: prose, effectiveRange: nil)
            as? NSColor == .systemBrown)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: token, effectiveRange: nil)
            as? NSColor == .systemRed)
        let redCalls = red.calls

        model.configuration = configuration(blue, bodyText: .systemGreen)
        model.revision = "blue"
        settle(host)

        #expect(textView.textStorage?.attribute(.foregroundColor, at: prose, effectiveRange: nil)
            as? NSColor == .systemGreen)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: token, effectiveRange: nil)
            as? NSColor == .systemBlue)
        #expect(blue.calls > 0)
        #expect(red.calls == redCalls)
    }

    private func configuration(
        _ highlighter: Highlighter,
        bodyText: NSColor
    ) -> MarkdownEditorConfiguration {
        MarkdownEditorConfiguration(
            theme: MarkdownEditorTheme(bodyText: bodyText),
            services: MarkdownEditorServices(syntaxHighlighter: highlighter)
        )
    }

    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

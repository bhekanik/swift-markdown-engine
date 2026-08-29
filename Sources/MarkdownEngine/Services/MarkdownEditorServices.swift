//
//  MarkdownEditorServices.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Protocols and default implementations for engine-side dependencies.
//
//  The Markdown editor engine resolves syntax highlighting through this protocol.
//  Embedders supply the concrete implementations; the engine never
//  reaches into the host app for any of these concerns.
//

import AppKit
import Foundation

// MARK: - Syntax Highlighting

/// Provides code-block font, background color, and syntax highlighting.
public protocol SyntaxHighlighter: Sendable {
    /// Monospace font used for fenced code blocks at the requested size.
    func codeFont(size: CGFloat) -> PlatformFont

    /// Background color used to fill code-block paragraphs. The engine
    /// also uses this color to detect which fragments are code blocks
    /// when drawing custom backgrounds.
    func backgroundColor() -> PlatformColor

    /// Highlight `code` written in `language`. Return an attributed string
    /// whose attributes carry per-token foreground colors. Return `nil` if
    /// no highlighting is available for this language.
    func highlight(code: String, language: String?) -> NSAttributedString?

    /// Notification name posted when the highlighter's appearance source
    /// changes (light/dark mode flip, theme switch). The engine subscribes
    /// to this notification so it can invalidate cached attributes.
    /// Return `nil` if the highlighter never changes after construction.
    var appearanceDidChangeNotification: Notification.Name? { get }
}

/// Default highlighter that produces no highlighting and supplies a
/// basic system monospace font on a transparent background.
public struct PlainTextSyntaxHighlighter: SyntaxHighlighter {
    public init() {}

    public func codeFont(size: CGFloat) -> PlatformFont {
        .engineMonospaced(ofSize: size)
    }

    public func backgroundColor() -> PlatformColor {
        PlatformColor.engineTextBackground.withAlphaComponent(0)
    }

    public func highlight(code: String, language: String?) -> NSAttributedString? {
        nil
    }

    public var appearanceDidChangeNotification: Notification.Name? { nil }
}

// MARK: - Event Bus

/// Optional notification-name bridge that lets the editor communicate with
/// surrounding UI without hard-coding any names of its own.
///
/// The engine observes the request notifications it is configured with and
/// posts the response notifications when supplied. Embedders that don't
/// need cross-view formatting commands simply leave every name `nil`.
public struct MarkdownEditorBus: Sendable {
    /// Posted by the host UI to request the engine apply bold styling.
    public var applyBoldRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply italic styling.
    public var applyItalicRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply a heading level.
    /// Expected `userInfo["level"] as? Int`.
    public var applyHeadingRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply highlight styling.
    public var applyHighlightRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply strikethrough styling.
    public var applyStrikethroughRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply inline code styling.
    public var applyInlineCodeRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply blockquote styling.
    public var applyBlockquoteRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply unordered list styling.
    public var applyUnorderedListRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply ordered list styling.
    public var applyOrderedListRequest: Notification.Name?
    /// Posted by the host UI to insert a Markdown link.
    /// Expected `userInfo["url"] as? String`.
    public var applyLinkRequest: Notification.Name?
    /// Posted by the host UI to insert a fenced code block at the cursor.
    public var applyCodeBlockRequest: Notification.Name?
    /// Posted by the host UI to insert a horizontal rule (`---`) at the cursor.
    public var applyHorizontalRuleRequest: Notification.Name?
    /// Posted by the host UI to insert a Markdown image.
    /// Expected `userInfo["url"] as? String`.
    public var applyImageRequest: Notification.Name?
    /// Posted by the engine after every selection change with `userInfo["isBold"] as? Bool`.
    public var selectionBoldDidChange: Notification.Name?
    /// Posted by the engine after every selection change with `userInfo["isItalic"] as? Bool`.
    public var selectionItalicDidChange: Notification.Name?
    /// Posted by the engine after every selection change with `userInfo["isHighlight"] as? Bool`.
    public var selectionHighlightDidChange: Notification.Name?
    /// Posted by the host UI to scroll an in-document find match into view
    /// and highlight all matches. Expected `userInfo["range"] as? NSRange`,
    /// `userInfo["currentIndex"] as? Int`, `userInfo["allRanges"] as? [NSRange]`.
    public var findScrollToRange: Notification.Name?
    /// Posted by the host UI to clear all in-document find highlights.
    public var findClearHighlights: Notification.Name?
    /// Posted by the host UI to run an in-document find against the engine's OWN
    /// text. Expected `userInfo["query"] as? String`, optional `userInfo["currentIndex"] as? Int`.
    /// Preferred over `findScrollToRange`, which trusts host-computed ranges.
    public var findQuery: Notification.Name?
    /// Posted by the engine in response to `findQuery` with `userInfo["count"] as? Int`
    /// (number of matches in the text), so the host can show "x of y".
    public var findResults: Notification.Name?
    /// Posted by the host UI to replace the current find match. Expected
    /// `userInfo["query"] as? String`, `userInfo["replacement"] as? String`,
    /// optional `userInfo["currentIndex"] as? Int`. The engine edits its own
    /// text (with undo), re-highlights the remaining matches, and
    /// posts `findResults` with the new count.
    public var replaceCurrent: Notification.Name?
    /// Posted by the host UI to replace every find match in one undo step.
    /// Expected `userInfo["query"] as? String`, `userInfo["replacement"] as? String`.
    /// The engine posts `findResults` with the count still matching afterward
    /// (non-zero only if the replacement itself contains the query).
    public var replaceAll: Notification.Name?

    public init(
        applyBoldRequest: Notification.Name? = nil,
        applyItalicRequest: Notification.Name? = nil,
        applyHeadingRequest: Notification.Name? = nil,
        applyHighlightRequest: Notification.Name? = nil,
        applyStrikethroughRequest: Notification.Name? = nil,
        applyInlineCodeRequest: Notification.Name? = nil,
        applyBlockquoteRequest: Notification.Name? = nil,
        applyUnorderedListRequest: Notification.Name? = nil,
        applyOrderedListRequest: Notification.Name? = nil,
        applyLinkRequest: Notification.Name? = nil,
        applyCodeBlockRequest: Notification.Name? = nil,
        applyHorizontalRuleRequest: Notification.Name? = nil,
        applyImageRequest: Notification.Name? = nil,
        selectionBoldDidChange: Notification.Name? = nil,
        selectionItalicDidChange: Notification.Name? = nil,
        selectionHighlightDidChange: Notification.Name? = nil,
        findScrollToRange: Notification.Name? = nil,
        findClearHighlights: Notification.Name? = nil,
        findQuery: Notification.Name? = nil,
        findResults: Notification.Name? = nil,
        replaceCurrent: Notification.Name? = nil,
        replaceAll: Notification.Name? = nil
    ) {
        self.applyBoldRequest = applyBoldRequest
        self.applyItalicRequest = applyItalicRequest
        self.applyHeadingRequest = applyHeadingRequest
        self.applyHighlightRequest = applyHighlightRequest
        self.applyStrikethroughRequest = applyStrikethroughRequest
        self.applyInlineCodeRequest = applyInlineCodeRequest
        self.applyBlockquoteRequest = applyBlockquoteRequest
        self.applyUnorderedListRequest = applyUnorderedListRequest
        self.applyOrderedListRequest = applyOrderedListRequest
        self.applyLinkRequest = applyLinkRequest
        self.applyCodeBlockRequest = applyCodeBlockRequest
        self.applyHorizontalRuleRequest = applyHorizontalRuleRequest
        self.applyImageRequest = applyImageRequest
        self.selectionBoldDidChange = selectionBoldDidChange
        self.selectionItalicDidChange = selectionItalicDidChange
        self.selectionHighlightDidChange = selectionHighlightDidChange
        self.findScrollToRange = findScrollToRange
        self.findClearHighlights = findClearHighlights
        self.findQuery = findQuery
        self.findResults = findResults
        self.replaceCurrent = replaceCurrent
        self.replaceAll = replaceAll
    }

    public static let `default` = MarkdownEditorBus()
}

// MARK: - Services Container

/// Bundles every external service the engine needs.
///
/// Held by ``MarkdownEditorConfiguration/services``. The engine reads its
/// dependencies exclusively from this container; embedders inject the
/// implementations they want.
public struct MarkdownEditorServices: Sendable {
    public var syntaxHighlighter: any SyntaxHighlighter
    public var bus: MarkdownEditorBus

    public init(
        syntaxHighlighter: any SyntaxHighlighter = PlainTextSyntaxHighlighter(),
        bus: MarkdownEditorBus = .default
    ) {
        self.syntaxHighlighter = syntaxHighlighter
        self.bus = bus
    }

    public static let `default` = MarkdownEditorServices()
}

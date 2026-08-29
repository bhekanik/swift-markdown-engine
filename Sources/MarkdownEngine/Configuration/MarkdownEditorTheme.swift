//
//  MarkdownEditorTheme.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Color palette for the Markdown editor engine.
//
//  All user-visible colors used by the engine are routed through this
//  struct. Defaults map to system colors so the editor adapts to light/
//  dark mode automatically. Embedders that want a custom palette (for
//  example, a sepia or high-contrast preset) can replace any subset of
//  the colors without touching engine source files.
//

import AppKit
import Foundation

// MARK: - Theme

/// Color palette consumed by the Markdown editor engine.
///
/// Every color the engine puts on screen is read from this struct, so a
/// single override is enough to retheme the entire editor. The defaults
/// reproduce a system-native look using dynamic system
/// colors, so light/dark-mode switching keeps working without extra code.
public struct MarkdownEditorTheme: Sendable {

    // MARK: Text colors

    /// Foreground color for plain body text and the typing caret.
    public var bodyText: PlatformColor
    /// Foreground color for de-emphasized text and most syntax markers.
    /// Defaults to `secondaryLabelColor` so it tracks the system style.
    public var mutedText: PlatformColor
    /// Foreground color for heading marker glyphs (`#`, `##`, …).
    public var headingMarker: PlatformColor

    // MARK: Links

    /// Foreground color for hyperlinks that resolve to an URL.
    public var link: PlatformColor
    /// Foreground color for incomplete `[text]` patterns (no URL yet).
    public var incompleteLink: PlatformColor

    // MARK: Find / search highlights

    /// Background color used to highlight all matches when the user is
    /// running an in-document search.
    ///
    /// The default is `.systemYellow` so embedders that don't customize
    /// this still get a sensible result. Apps with their own brand color
    /// (for example, the Nodes app uses its custom yellow) should override
    /// this to match their palette.
    public var findMatchHighlight: PlatformColor
    /// Background color used to highlight the currently-focused match
    /// during in-document search. Typically a stronger version of
    /// ``findMatchHighlight``.
    public var findCurrentMatchHighlight: PlatformColor

    // MARK: Strikethrough / decoration

    /// Stroke color used for strikethrough decorations
    /// (e.g. completed task list items, horizontal rules).
    public var strikethroughColor: PlatformColor

    // MARK: Highlight

    /// Background color used for `==highlight==` inline markup.
    public var highlightColor: PlatformColor

    // MARK: Init

    public init(
        bodyText: PlatformColor = .engineLabel,
        mutedText: PlatformColor = .engineSecondaryLabel,
        headingMarker: PlatformColor = .gray,
        link: PlatformColor = .engineLink,
        incompleteLink: PlatformColor = .systemBlue,
        findMatchHighlight: PlatformColor = .systemYellow,
        findCurrentMatchHighlight: PlatformColor = .systemYellow,
        strikethroughColor: PlatformColor = .engineLabel,
        highlightColor: PlatformColor = .systemOrange.withAlphaComponent(0.4)
    ) {
        self.bodyText = bodyText
        self.mutedText = mutedText
        self.headingMarker = headingMarker
        self.link = link
        self.incompleteLink = incompleteLink
        self.findMatchHighlight = findMatchHighlight
        self.findCurrentMatchHighlight = findCurrentMatchHighlight
        self.strikethroughColor = strikethroughColor
        self.highlightColor = highlightColor
    }

    /// System-native palette built from dynamic system colors.
    ///
    /// Use this if you want the engine to look like a stock macOS
    /// `NSTextView`. It's also the default when no theme is supplied.
    public static let `default` = MarkdownEditorTheme()
}

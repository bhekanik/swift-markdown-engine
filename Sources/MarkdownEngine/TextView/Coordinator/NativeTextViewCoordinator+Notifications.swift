//
//  NativeTextViewCoordinator+Notifications.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Bus-notification handlers wired up by `subscribeToBusNotifications`.
//  These translate embedder-posted requests (apply bold / italic / heading
//  level) into the corresponding ContextMenu actions, and refresh styling
//  when the syntax highlighter signals an appearance change.
//

import AppKit

extension NativeTextViewCoordinator {
    func handleBoldNotification() {
        didMarkdownBold(nil)
    }

    func handleItalicNotification() {
        didMarkdownItalic(nil)
    }

    func handleHighlightNotification() {
        didMarkdownHighlight(nil)
    }

    func handleHeadingNotification(level: Int) {
        let item = NSMenuItem()
        item.tag = level
        didMarkdownHeading(item)
    }

    func handleStrikethroughNotification() {
        didMarkdownStrikethrough(nil)
    }

    func handleInlineCodeNotification() {
        didMarkdownInlineCode(nil)
    }

    func handleBlockquoteNotification() {
        didMarkdownBlockquote(nil)
    }

    func handleUnorderedListNotification() {
        didMarkdownUnorderedList(nil)
    }

    func handleOrderedListNotification() {
        didMarkdownOrderedList(nil)
    }

    func handleLinkNotification(url: String) {
        didMarkdownLink(url: url)
    }

    func handleCodeBlockNotification() {
        didMarkdownCodeBlock(nil)
    }

    func handleHorizontalRuleNotification() {
        didMarkdownHorizontalRule(nil)
    }

    func handleImageNotification(url: String) {
        didMarkdownImage(url: url)
    }

    @objc func handleAppearanceChange(_ notification: Notification) {
        guard let tv = textView else { return }
        // Only react if the notification came from our own text view or from nil (system-wide)
        if let sender = notification.object as? NSTextView, sender !== tv {
            return
        }
        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)
        restyleTextView(tv, paragraphCandidates: [fullRange])
    }
}

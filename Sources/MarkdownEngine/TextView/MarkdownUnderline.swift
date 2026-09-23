//
//  MarkdownUnderline.swift
//  MarkdownEngine
//

import AppKit

/// One wavy underline under a UTF-16 source range, in a colour.
public struct MarkdownUnderline: Equatable {
    public var range: NSRange
    public var color: NSColor

    public init(range: NSRange, color: NSColor) {
        self.range = range
        self.color = color
    }
}

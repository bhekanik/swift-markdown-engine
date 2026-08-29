//
//  HeadingHelpers.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Small helper values for heading size/spacing, plus shared text measurements.
import AppKit

enum HeadingHelpers {

    /// Memoized string-width measurement. `size(withAttributes:)` is a full CoreText
    /// measure (~31µs); the styler calls this thousands of times per open on a small set
    /// of repeated strings, including list markers (`- `, `1. `). Same (text, font) → same width, so the cache
    /// is byte-identical to the direct call. `NSCache` bounds memory and is thread-safe.
    private static let widthCache: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>()
        c.countLimit = 4096
        return c
    }()

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(text)" as NSString
        if let cached = widthCache.object(forKey: key) {
            return CGFloat(cached.doubleValue)
        }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        widthCache.setObject(NSNumber(value: Double(width)), forKey: key)
        return width
    }
}

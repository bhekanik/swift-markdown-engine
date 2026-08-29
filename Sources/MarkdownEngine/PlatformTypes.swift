//
//  PlatformTypes.swift
//  MarkdownEngine
//
//  One name per UI primitive, so the embedder-facing contract does not spell
//  AppKit.
//

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// `NSFont` on macOS, `UIFont` on iOS.
public typealias PlatformFont = NSFont
/// `NSColor` on macOS, `UIColor` on iOS.
public typealias PlatformColor = NSColor
/// `NSImage` on macOS, `UIImage` on iOS.
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit

public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
#endif

// The view layer (`NativeTextViewWrapper`, the coordinator, the layout
// fragment) is AppKit and stays AppKit — `UITextView` has no equivalent
// delegate surface, coalescing model or `NSMenu`, so the iOS port is a
// rewrite of that layer, not a typealias away. What these names buy is that
// the SERVICE PROTOCOLS and the THEME — the contract an embedder implements —
// are already platform-neutral, so the port does not change them and every
// embedder does not pay for it twice.

public extension PlatformColor {
    /// The system's primary text colour.
    static var engineLabel: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        .labelColor
        #else
        .label
        #endif
    }

    /// The system's secondary text colour.
    static var engineSecondaryLabel: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    /// The system's link colour.
    static var engineLink: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        .linkColor
        #else
        .link
        #endif
    }

    /// The system's editable-text background.
    static var engineTextBackground: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        .textBackgroundColor
        #else
        .systemBackground
        #endif
    }
}

public extension PlatformFont {
    /// The system monospaced face at `size`, regular weight.
    static func engineMonospaced(ofSize size: CGFloat) -> PlatformFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension NSAppearance {
    /// The appearance to resolve colours under when there is no view to ask.
    ///
    /// `NSApp` is an implicitly unwrapped optional and is nil in any process
    /// that has not touched `NSApplication.shared` — a command-line tool, a
    /// `swift test` bundle, a headless render through ``MarkdownRendering``.
    /// Reading `NSApp.effectiveAppearance` there does not return nil, it traps,
    /// so a document containing a table used to kill the process rather than
    /// draw in the wrong palette. Optional-chaining `NSApp` is safe and does
    /// NOT instantiate an application the way `NSApplication.shared` would;
    /// `currentDrawing()` then answers from the drawing context, or `.aqua`.
    static var engineFallback: NSAppearance {
        NSApp?.effectiveAppearance ?? .currentDrawing()
    }
}
#endif

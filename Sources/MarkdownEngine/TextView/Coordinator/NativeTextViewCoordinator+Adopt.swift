//
//  NativeTextViewCoordinator+Adopt.swift
//  MarkdownEngine
//
//  Driving an NSTextView the embedder built, without SwiftUI.
//

import AppKit

public extension NativeTextViewCoordinator {
    /// Take over an `NSTextView` the caller created: become its delegate, wire
    /// the TextKit 2 layout bridge and fragment drawing, set the base font,
    /// style the document, and attach the controller so `applyPatch` and the
    /// text-view seam work.
    ///
    /// This is the AppKit entry point. `NativeTextViewWrapper` is the SwiftUI
    /// one and does strictly more — it also builds the scroll container, the
    /// reading column, overscroll and the wide-table overlays, none of which
    /// exist without a scroll view to hang them on. Use this when you own the
    /// view hierarchy (an AppKit host, a headless test); use the wrapper
    /// otherwise.
    ///
    /// Get a coordinator from `NativeTextViewWrapper(...).makeCoordinator()`,
    /// which seeds it with the configuration, fonts and controller you passed.
    func adopt(_ textView: NSTextView, text: String) {
        self.textView = textView
        textView.delegate = self
        textView.isRichText = true
        textView.allowsUndo = configuration.undo == .engine
        if let textLayoutManager = textView.textLayoutManager {
            let delegate = MarkdownLayoutManagerDelegate()
            layoutDelegate = delegate
            textLayoutManager.delegate = delegate
            layoutBridge = LayoutBridge(textLayoutManager)
        }
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        rebuildTextStorageAndStyle(textView, from: text)
        previousDisplayLength = (textView.string as NSString).length
        didInitialFormatting = true
        editorController?.attach(textView: textView, coordinator: self)
    }
}

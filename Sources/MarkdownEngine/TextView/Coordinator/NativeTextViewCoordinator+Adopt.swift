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
    /// Returns `false` when that controller already drives another view. The
    /// refused view remains isolated and inert; call `adopt` again after the
    /// controller becomes available if this view should take over later.
    @discardableResult
    func adopt(_ textView: NSTextView, text: String) -> Bool {
        let requestedController = editorController ?? requestedControllerWhileDetached
        if let requestedController {
            let hadAuthoritativeDocument = requestedController.hasLoadedDocument
            guard requestedController.attach(
                textView: textView,
                coordinator: self,
                notifyEmbedder: false
            ) else {
                // A failed admission must not run styling services. They are
                // arbitrary embedder code and may reach the controller that
                // still belongs to its current view.
                guard self.textView == nil || self.textView === textView else {
                    return false
                }
                self.textView = textView
                editorController = nil
                requestedControllerWhileDetached = requestedController
                isDetachedFromDocument = true
                textView.string = text
                return false
            }

            self.textView = textView
            editorController = requestedController
            requestedControllerWhileDetached = nil
            isDetachedFromDocument = false
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            if let layoutManager = textView.textLayoutManager {
                requestedController.adopt(layoutManager: layoutManager)
            }
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            let authoritativeText = hadAuthoritativeDocument ? textView.string : text
            configureAdoptedTextView(
                textView,
                text: authoritativeText,
                notifyTextFinder: false
            )
            requestedController.markDocumentLoaded()
            requestedController.notifyEmbedderOfAttachment(textView)

            guard editorController === requestedController,
                  requestedController.textView === textView else {
                editorController = nil
                requestedControllerWhileDetached = requestedController
                isDetachedFromDocument = true
                if let layoutManager = textView.textLayoutManager,
                   layoutManager.textContentManager == nil {
                    NSTextContentStorage().addTextLayoutManager(layoutManager)
                }
                configureAdoptedTextView(textView, text: authoritativeText)
                return false
            }
            return true
        }

        self.textView = textView
        requestedControllerWhileDetached = nil
        isDetachedFromDocument = false
        configureAdoptedTextView(textView, text: text)
        return true
    }

    private func configureAdoptedTextView(
        _ textView: NSTextView,
        text: String,
        notifyTextFinder: Bool = true
    ) {
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
        rebuildTextStorageAndStyle(
            textView,
            from: text,
            notifyTextFinder: notifyTextFinder
        )
        previousDisplayLength = (textView.string as NSString).length
        didInitialFormatting = true
    }
}

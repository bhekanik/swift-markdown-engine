//
//  NativeTextView+CaretWorkarounds.swift
//  MarkdownEngine
//
//  Caret-indicator workarounds: block-image hide/resize + trailing-`\n` Y-snap (FB22524198).
//
//  The block/hollow caret shape itself is no longer handled here: resizing
//  AppKit's indicator was unverifiable in a real key window (see
//  `NativeTextView+VimCaretOverlay.swift`), so the shape is drawn by a layer
//  we own and the indicator is hidden while that layer is active.
//

import AppKit

extension NativeTextView {
    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        applyBlockImageCaretPolicy()
        refreshVimCaretOverlay()
        DispatchQueue.main.async { [weak self] in self?.fixPhantomTrailingCaret() }
    }

    func applyBlockImageCaretPolicy() {
        let (hide, resize) = blockImageCaretDecision()
        for sub in subviews where type(of: sub) == NSTextInsertionIndicator.self {
            if !hide && resize { resizeIndicatorToLayoutCaret(sub) }
            if sub.isHidden != hide { sub.isHidden = hide }
        }
    }

    /// When the caret sits in a paragraph with block images: hidden entirely
    /// if any block image carries no layout caret (it would render through
    /// the image), or snapped to the layout caret's height otherwise (the
    /// indicator keeps the collapsed image's full height otherwise). Shared
    /// with the vim caret overlay, which must vanish on the same hiding
    /// cases even though it takes its frame from layout, not the indicator.
    func blockImageCaretDecision() -> (hide: Bool, resize: Bool) {
        guard let ts = textStorage else { return (false, false) }
        let sel = selectedRange()
        if sel.length != 0 || sel.location > ts.length {
            return (true, false)
        }
        guard sel.location < ts.length else { return (false, false) }
        let paraRange = (ts.string as NSString).paragraphRange(
            for: NSRange(location: sel.location, length: 0)
        )
        var hide = false
        var resize = false
        ts.enumerateAttribute(.renderedImageIsBlock, in: paraRange, options: []) { value, range, stop in
            guard value as? Bool == true else { return }
            if ts.attribute(.renderedBlockOffsetY, at: range.location, effectiveRange: nil) != nil {
                resize = true
            } else {
                hide = true
                stop.pointee = true
            }
        }
        return (hide, resize)
    }

    /// After collapsed→visible, the indicator frame stays at image height; snap it to the layout manager's actual caret rect.
    func resizeIndicatorToLayoutCaret(_ indicator: NSView) {
        guard let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let docLoc = tcs.location(tcs.documentRange.location, offsetBy: selectedRange().location) else { return }
        var layoutRect: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: docLoc), type: .standard, options: [.rangeNotRequired]) { _, f, _, _ in
            layoutRect = f; return false
        }
        guard let r = layoutRect, r.height > 0,
              indicator.frame.height > r.height + 1 else { return }
        isApplyingCaretShift = true
        indicator.frame = CGRect(x: indicator.frame.origin.x, y: r.origin.y,
                                 width: indicator.frame.width, height: r.height)
        isApplyingCaretShift = false
    }

    /// FB22524198: AppKit drops the trailing-`\n` caret onto the previous line's top — snap it to `lastLineMaxY + paragraphSpacing` instead. (Companion to FB15131180; this one fixes Y, the other fixes height.)
    func fixPhantomTrailingCaret() {
        if let indicator = subviews.first(where: { type(of: $0) == NSTextInsertionIndicator.self }),
           observedCaretIndicator !== indicator {
            caretIndicatorObservation?.invalidate()
            observedCaretIndicator = indicator
            caretIndicatorObservation = indicator.observe(\.frame, options: [.new]) { [weak self] _, _ in
                // NSTextInsertionIndicator frame changes are driven by AppKit on the main thread.
                MainActor.assumeIsolated {
                    guard let self, !self.isApplyingCaretShift else { return }
                    self.applyBlockImageCaretPolicy()
                    self.refreshVimCaretOverlay()
                    self.fixPhantomTrailingCaret()
                }
            }
        }
        guard let ts = textStorage, let indicator = observedCaretIndicator,
              let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else { return }
        let sel = selectedRange()
        let ns = ts.string as NSString
        guard sel.length == 0, sel.location == ns.length, ns.length > 0,
              ns.character(at: ns.length - 1) == 0x0A,
              let trailingLoc = tcs.location(tcs.documentRange.location, offsetBy: ns.length - 1) else {
            return
        }
        var desiredY: CGFloat?
        tlm.enumerateTextLayoutFragments(from: trailingLoc, options: [.ensuresLayout]) { fragment in
            // Use the LAST text line (length > 0) so multi-line wrapped paragraphs aren't pulled to the first line.
            let lastTextLine = fragment.textLineFragments.last { $0.characterRange.length > 0 }
                ?? fragment.textLineFragments.last
            guard let line = lastTextLine else { return false }
            let lineMaxY = fragment.layoutFragmentFrame.origin.y + line.typographicBounds.maxY
            let style = ts.attribute(.paragraphStyle, at: ns.length - 1, effectiveRange: nil) as? NSParagraphStyle
            // Layout-fragment Y is textContainer-relative; the indicator frame is textView-relative — add the textContainerInset offset so the snap stays correct when an embedder configures non-zero text insets.
            desiredY = lineMaxY + (style?.paragraphSpacing ?? 0) + self.textContainerInset.height
            return false
        }
        guard let desiredY, abs(indicator.frame.origin.y - desiredY) >= 0.5 else { return }
        isApplyingCaretShift = true
        indicator.frame.origin.y = desiredY
        isApplyingCaretShift = false
    }
}

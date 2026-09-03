//
//  NativeTextView+CaretWorkarounds.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Caret-indicator workarounds: block-image hide/resize + trailing-`\n` Y-snap (FB22524198).
//

import AppKit

extension NativeTextView {
    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        applyBlockImageCaretPolicy()
        DispatchQueue.main.async { [weak self] in self?.fixPhantomTrailingCaret() }
    }

    func applyBlockImageCaretPolicy() {
        let indicators = subviews.filter { type(of: $0) == NSTextInsertionIndicator.self }
        guard !indicators.isEmpty else { return }

        var hide = false
        var resize = false
        if let ts = textStorage {
            let sel = selectedRange()
            if sel.length != 0 || sel.location > ts.length {
                hide = true
            } else if sel.location < ts.length {
                let paraRange = (ts.string as NSString).paragraphRange(
                    for: NSRange(location: sel.location, length: 0)
                )
                ts.enumerateAttribute(.renderedImageIsBlock, in: paraRange, options: []) { value, range, stop in
                    guard value as? Bool == true else { return }
                    if ts.attribute(.renderedBlockOffsetY, at: range.location, effectiveRange: nil) != nil {
                        resize = true
                    } else {
                        hide = true
                        stop.pointee = true
                    }
                }
            }
        }

        for sub in indicators {
            if !hide && resize { resizeIndicatorToLayoutCaret(sub) }
            if !hide { applyCaretShape(to: sub) }
            if sub.isHidden != hide { sub.isHidden = hide }
        }
    }

    /// Widen the indicator to the character cell for ``MarkdownCaretShape/block``
    /// and outline it for ``MarkdownCaretShape/hollow``.
    ///
    /// AppKit rewrites the indicator frame on every selection change and lays
    /// the bar out itself, so this runs from the same two places the
    /// block-image workaround does (`updateInsertionPointStateAndRestartTimer`
    /// and the frame KVO) and re-applies the width each time. Half alpha keeps
    /// the character under the block readable, which terminal vim gets for
    /// free by inverting the cell. The hollow caret keeps the character fully
    /// readable: a much fainter fill plus a 1 pt outline, drawn by a sibling of
    /// the indicator so the indicator's own alpha never fades the outline too.
    private func applyCaretShape(to indicator: NSView) {
        let shape = editorController?.caretShape ?? .bar
        switch shape {
        case .bar:
            guard let barWidth = caretBarWidth else { return }
            caretBarWidth = nil
            isApplyingCaretShift = true
            indicator.frame.size.width = barWidth
            indicator.alphaValue = 1
            isApplyingCaretShift = false
            removeHollowCaretBorder()
        case .block:
            widenIndicatorForBlockCaret(indicator)
            indicator.alphaValue = 0.45
            removeHollowCaretBorder()
        case .hollow:
            widenIndicatorForBlockCaret(indicator)
            indicator.alphaValue = 0.12
            installHollowCaretBorder(for: indicator)
        }
    }

    private func widenIndicatorForBlockCaret(_ indicator: NSView) {
        let width = blockCaretWidth()
        if caretBarWidth == nil { caretBarWidth = indicator.frame.width }
        isApplyingCaretShift = true
        if abs(indicator.frame.width - width) >= 0.5 { indicator.frame.size.width = width }
        isApplyingCaretShift = false
    }

    /// The outline tracks the indicator frame because this whole policy reruns
    /// from the indicator's frame KVO, which AppKit fires on every caret move.
    private func installHollowCaretBorder(for indicator: NSView) {
        let border = hollowCaretBorder ?? HollowCaretBorderView()
        if border.superview == nil {
            indicator.superview?.addSubview(border)
        }
        hollowCaretBorder = border
        border.update(color: insertionPointColor ?? .textInsertionPointColor)
        border.frame = indicator.frame
    }

    private func removeHollowCaretBorder() {
        hollowCaretBorder?.removeFromSuperview()
        hollowCaretBorder = nil
    }

    /// Advance of the grapheme cluster at the caret, or an em at a line end or
    /// the end of the document, where there is no glyph to cover.
    private func blockCaretWidth() -> CGFloat {
        let text = string as NSString
        let caret = selectedRange().location
        if caret < text.length,
           let tlm = textLayoutManager,
           let tcs = tlm.textContentManager as? NSTextContentStorage,
           let start = tcs.location(tcs.documentRange.location, offsetBy: caret),
           let end = tcs.location(start, offsetBy: text.rangeOfComposedCharacterSequence(at: caret).length),
           let range = NSTextRange(location: start, end: end) {
            var width: CGFloat = 0
            tlm.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
                width = frame.width
                return false
            }
            if width >= 1 { return width }
        }
        return ("m" as NSString).size(withAttributes: [.font: font ?? baseFont]).width
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

/// The 1 pt outline of a ``MarkdownCaretShape/hollow`` caret.
///
/// A sibling of the indicator rather than a subview or an indicator layer
/// border: the indicator blinks by fading its own alpha, and anything
/// composited inside it would fade with it — an outline that disappears
/// half the time reads as a flickering block, not a hollow caret.
final class HollowCaretBorderView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The caret never receives clicks anyway; keep this out of the
    /// text view's responder path entirely.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(color: NSColor) {
        layer?.borderColor = color.cgColor
        layer?.borderWidth = 1
    }
}

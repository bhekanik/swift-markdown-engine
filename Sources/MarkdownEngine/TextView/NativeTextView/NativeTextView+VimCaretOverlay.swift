//
//  NativeTextView+VimCaretOverlay.swift
//  MarkdownEngine
//
//  The block/hollow caret, drawn by a layer of our own rather than by
//  resizing AppKit's insertion indicator.
//
//  Resizing `NSTextInsertionIndicator` only worked in a test process: in a
//  key window AppKit rewrites the indicator frame after every caret move with
//  `setFrameSize:`/`setFrameOrigin:`, which do not fire the `frame` KVO the
//  policy listened to, so the width collapsed back to the bar and the bar
//  landed at AppKit's recentred origin (FB-of-ours, unverifiable in-process —
//  tests cannot make a key window). Drawing the caret ourselves removes the
//  dependence on that private dance entirely: every input (the segment rects)
//  and every update site (selection, text, layout) is testable.
//

import AppKit

/// The drawn block/hollow caret. A plain `CALayer` would need a layer-backed
/// text view to live in; a view brings its own layer and works everywhere.
///
/// The caret never receives clicks or accessibility focus: it is a cursor,
/// not content, so hit-testing returns `nil`.
public final class VimCaretOverlayView: NSView {
    /// Fill opacity of the ``block`` shape, matching terminal vim's
    /// half-inverted cell so the character underneath stays readable.
    public static let blockFillAlpha: CGFloat = 0.45
    /// Fill opacity of the ``hollow`` shape: faint, because the outline is
    /// what marks the cell.
    public static let hollowFillAlpha: CGFloat = 0.15
    /// Outline width of the ``hollow`` shape.
    public static let hollowBorderWidth: CGFloat = 1
    /// AppKit halves the insertion point's alpha in a non-key window; so do we.
    public static let inactiveDimming: CGFloat = 0.5

    public private(set) var isHollow = false
    /// Fill alpha in force, for an embedder asserting the styling.
    public private(set) var fillAlpha: CGFloat = 0
    /// `true` while the window has lost key status, like an inactive
    /// document's dimmed insertion point. Driven by the observed key-window
    /// transitions, not polled, so a test harness window that was never key
    /// stays undimmed.
    public private(set) var isDimmed = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(shape: MarkdownCaretShape, color: NSColor, dimmed: Bool) {
        isHollow = shape == .hollow
        isDimmed = dimmed
        // Dimming scales the alpha rather than replacing it, so the hollow's
        // faint fill stays fainter than the block's even when dimmed.
        fillAlpha = (isHollow ? Self.hollowFillAlpha : Self.blockFillAlpha)
            * (dimmed ? Self.inactiveDimming : 1)
        layer?.backgroundColor = color.withAlphaComponent(fillAlpha).cgColor
        layer?.borderColor = isHollow ? color.cgColor : nil
        layer?.borderWidth = isHollow ? Self.hollowBorderWidth : 0
    }
}

extension NativeTextView {
    /// The block/hollow caret layer, exposed so an embedder can assert how it
    /// is drawn. Lives in the view hierarchy, hence weak here.
    func installVimCaretOverlayIfNeeded() -> VimCaretOverlayView {
        if let vimCaretOverlay { return vimCaretOverlay }
        let overlay = VimCaretOverlayView()
        addSubview(overlay)
        vimCaretOverlay = overlay
        return overlay
    }

    /// Recompute the overlay frame and visibility for the current shape,
    /// selection and layout. Safe to call from any update site; the `.bar`
    /// steady state exits before touching subviews.
    func refreshVimCaretOverlay() {
        installCaretOverlayHooksIfNeeded()
        let shape = editorController?.caretShape ?? .bar

        if shape == .bar, lastAppliedCaretShape == .bar, vimCaretOverlay == nil {
            return // The steady state of every non-vim document: cost nothing.
        }
        lastAppliedCaretShape = shape

        setHiddenCaretShapeOnSystemIndicators(shape != .bar)

        switch shape {
        case .bar:
            vimCaretOverlay?.removeFromSuperview()
            vimCaretOverlay = nil
        case .block, .hollow:
            let (blockImageHide, _) = blockImageCaretDecision()
            let hasSelection = selectedRange().length != 0
                || selectedRange().location > (textStorage?.length ?? 0)
            guard !hasSelection, !blockImageHide,
                  caretOverlayIsFirstResponder,
                  let rect = vimCaretRect() else {
                vimCaretOverlay?.isHidden = true
                return
            }
            let overlay = installVimCaretOverlayIfNeeded()
            overlay.isHidden = false
            // No frame animation: a caret that slides between edits reads as
            // text moving, not as the caret travelling.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.frame = rect
            CATransaction.commit()
            overlay.apply(
                shape: shape,
                color: insertionPointColor ?? .textInsertionPointColor,
                dimmed: overlayWindowDidResignKey
            )
        }
    }

    /// The rect of the block caret: the glyph cell of the grapheme cluster at
    /// the insertion point — TextKit's own segment rect, so wrapped lines,
    /// CJK and clusters are all right by construction — with an em width
    /// where no glyph covers the caret (a line end, the end of the document),
    /// and the trailing-`\n` Y snap from FB22524198.
    func vimCaretRect() -> CGRect? {
        guard let ts = textStorage,
              let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let start = tcs.location(tcs.documentRange.location, offsetBy: selectedRange().location)
        else { return nil }
        let ns = ts.string as NSString
        let caret = selectedRange().location
        guard caret <= ns.length else { return nil }
        let em = ("m" as NSString).size(withAttributes: [.font: font ?? baseFont]).width

        var width = em
        if caret < ns.length,
           let end = tcs.location(start, offsetBy: ns.rangeOfComposedCharacterSequence(at: caret).length),
           let cluster = NSTextRange(location: start, end: end) {
            var clusterWidth: CGFloat = 0
            tlm.enumerateTextSegments(in: cluster, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
                clusterWidth = frame.width
                return false
            }
            if clusterWidth >= 1 { width = clusterWidth }
        }

        let containerOrigin = textContainerOrigin
        var rect: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: start), type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            rect = frame
            return false
        }

        if let snapped = trailingNewlineCaretLine(), isTrailingNewlineAtEnd {
            return CGRect(
                x: rect.map { $0.origin.x + containerOrigin.x } ?? containerOrigin.x,
                y: snapped.y,
                width: width,
                height: snapped.height
            )
        }
        if var r = rect {
            r.origin.x += containerOrigin.x
            r.origin.y += containerOrigin.y
            r.size.width = width
            return r
        }
        // No segment exists only for an empty document: the caret sits at the
        // container origin, one em wide, one line tall.
        let lineHeight = ceil((font ?? baseFont).boundingRectForFont.height)
        return CGRect(x: containerOrigin.x, y: containerOrigin.y, width: width, height: lineHeight)
    }

    /// FB22524198: TextKit places the caret after a trailing `\n` on the
    /// previous line's top. The segment rect there is wrong, so the last
    /// text line supplies the Y (and the line height for the overlay).
    private var isTrailingNewlineAtEnd: Bool {
        guard let ts = textStorage else { return false }
        let ns = ts.string as NSString
        let sel = selectedRange()
        return sel.length == 0 && sel.location == ns.length && ns.length > 0
            && ns.character(at: ns.length - 1) == 0x0A
    }

    /// `(y, height)` of the caret line after a trailing newline, in text view
    /// coordinates; the fragment math `fixPhantomTrailingCaret` snap uses.
    private func trailingNewlineCaretLine() -> (y: CGFloat, height: CGFloat)? {
        guard let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else { return nil }
        let ns = string as NSString
        guard let trailingLoc = tcs.location(tcs.documentRange.location, offsetBy: ns.length - 1)
        else { return nil }
        var line: (y: CGFloat, height: CGFloat)?
        tlm.enumerateTextLayoutFragments(from: trailingLoc, options: [.ensuresLayout]) { fragment in
            let lastTextLine = fragment.textLineFragments.last { $0.characterRange.length > 0 }
                ?? fragment.textLineFragments.last
            guard let textLine = lastTextLine else { return false }
            let lineMaxY = fragment.layoutFragmentFrame.origin.y + textLine.typographicBounds.maxY
            let style = (textStorage?.attribute(
                .paragraphStyle, at: ns.length - 1, effectiveRange: nil) as? NSParagraphStyle)
            line = (
                y: lineMaxY + (style?.paragraphSpacing ?? 0) + self.textContainerInset.height,
                height: textLine.typographicBounds.height
            )
            return false
        }
        return line
    }

    // MARK: - Update sites

    /// Selector-based observers throughout: the notification center holds
    /// them weakly, so they die with the view without a deinit that would
    /// have to reach MainActor-isolated state, and every posting site here
    /// (selection, text change, window key transitions) is the main thread.
    private func installCaretOverlayHooksIfNeeded() {
        guard !caretOverlayHooksInstalled else { return }
        caretOverlayHooksInstalled = true
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(caretOverlayDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: self
        )
        center.addObserver(
            self, selector: #selector(caretOverlayDidChange(_:)),
            name: NSText.didChangeNotification, object: self
        )
    }

    @objc private func caretOverlayDidChange(_ note: Notification) {
        refreshVimCaretOverlay()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // The key observers watch the window the view is leaving; the name +
        // self + nil-object removal drops exactly those.
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            let center = NotificationCenter.default
            center.addObserver(
                self, selector: #selector(caretOverlayWindowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: window
            )
            center.addObserver(
                self, selector: #selector(caretOverlayWindowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification, object: window
            )
        }
        refreshVimCaretOverlay()
    }

    @objc private func caretOverlayWindowDidBecomeKey(_ note: Notification) {
        overlayWindowDidResignKey = false
        refreshVimCaretOverlay()
    }

    @objc private func caretOverlayWindowDidResignKey(_ note: Notification) {
        overlayWindowDidResignKey = true
        refreshVimCaretOverlay()
    }

    override func layout() {
        super.layout()
        refreshVimCaretOverlay()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // The window still reports the old first responder while these
        // transitions run, so the state is tracked here rather than probed
        // from `window.firstResponder`.
        if became { caretOverlayIsFirstResponder = true }
        refreshVimCaretOverlay()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { caretOverlayIsFirstResponder = false }
        refreshVimCaretOverlay()
        return resigned
    }

    /// Hide every `NSTextInsertionIndicator` — AppKit only ever creates one —
    /// while a non-bar shape owns the caret, and give the display mode back on
    /// `.bar`.
    ///
    /// `displayMode = .hidden` rather than a clear `insertionPointColor`:
    /// hidden is the mode that also parks AppKit's blink work, while a clear
    /// colour keeps the indicator blinking — main-thread redraws on a timer
    /// — for a caret nobody sees. The mode is per-indicator, and AppKit
    /// recreates indicators as windows gain key status, so it is re-applied
    /// from `updateInsertionPointStateAndRestartTimer(_:)`, the call AppKit
    /// makes whenever it installs or moves an indicator.
    private func setHiddenCaretShapeOnSystemIndicators(_ hidden: Bool) {
        for sub in subviews where type(of: sub) == NSTextInsertionIndicator.self {
            (sub as? NSTextInsertionIndicator)?.displayMode = hidden ? .hidden : .automatic
        }
    }
}

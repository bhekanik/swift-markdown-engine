//
//  NativeTextView+FrameAndOverscroll.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Frame-size management, content-height measurement (TextKit-2 last-fragment
//  + end-segment pattern), bottom-overscroll application, and transient-shrink
//  scroll-position restoration.
//

import AppKit

extension NativeTextView {
    /// Real content height including overscroll, excluding the click-below-text inflation.
    var scrollableContentHeight: CGFloat {
        max(ceil(baseContentHeight + activeBottomOverscroll), 0)
    }

    func recalcOverscroll(
        for scrollView: NSScrollView,
        targetWidth: CGFloat? = nil,
        debugTag: String = "?"
    ) {
        scrollView.contentInsets.bottom = 0

        let lineHeight = layoutBridgeDefaultLineHeight(for: self.baseFont, using: layoutBridge)
        // File switch/resize forces full layout until height settles; typing stays O(edit).
        if debugTag == "?" { pendingFullLayoutMeasure = true }
        let forcedFullLayout = pendingFullLayoutMeasure
        let measured = measuredBaseContentHeight(
            minimumHeight: lineHeight,
            forceFullLayout: pendingFullLayoutMeasure
        )
        let visibleHeight = scrollView.contentView.bounds.height
        let resolvedOverscroll = resolvedOverscroll(
            baseContentHeight: measured,
            visibleHeight: visibleHeight,
            lineHeight: lineHeight
        )

        let baseHeightChanged = abs(measured - baseContentHeight) > 0.5
        let overscrollChanged = abs(resolvedOverscroll - activeBottomOverscroll) > 0.5
        // Height settled → stop forcing full layout (until the next switch/resize).
        if !(baseHeightChanged || overscrollChanged) { pendingFullLayoutMeasure = false }
        // A persistent fullLayout=1 with hChanged/osChanged flipping every
        // keystroke = the bistable-height loop: every keystroke then pays a
        // FULL document ensureLayout inside the overscroll span.
        PerfTrace.note {
            "overscroll[\(debugTag)]: fullLayout=\(forcedFullLayout ? 1 : 0) h=\(Int(measured))\(baseHeightChanged ? " hChanged" : "")\(overscrollChanged ? " osChanged" : "")"
        }
        guard baseHeightChanged || overscrollChanged else { return }
        baseContentHeight = measured
        activeBottomOverscroll = resolvedOverscroll
        applyManagedFrameSize(width: targetWidth ?? frame.size.width)
    }

    /// Re-run the policy with the current base content height without re-measuring.
    func reapplyOverscrollPolicy(for scrollView: NSScrollView) {
        let lineHeight = layoutBridgeDefaultLineHeight(for: self.baseFont, using: layoutBridge)
        let resolved = resolvedOverscroll(
            baseContentHeight: baseContentHeight,
            visibleHeight: scrollView.contentView.bounds.height,
            lineHeight: lineHeight
        )
        guard abs(resolved - activeBottomOverscroll) > 0.5 else { return }
        activeBottomOverscroll = resolved
        applyManagedFrameSize(width: frame.size.width)
    }

    private func resolvedOverscroll(
        baseContentHeight: CGFloat,
        visibleHeight: CGFloat,
        lineHeight: CGFloat
    ) -> CGFloat {
        // Overscroll is a scroll-comfort affordance; meaningless without internal scrolling.
        guard configuration.heightBehavior == .scrolls else { return 0 }
        let policy = BottomOverscrollPolicy(
            overscrollPercent: overscrollPercent,
            minOverscrollPoints: minOverscrollPoints,
            maxOverscrollPoints: maxOverscrollPoints,
            activationStartFraction: configuration.overscroll.activationStartFraction,
            activationRangeFraction: configuration.overscroll.activationRangeFraction
        )
        return policy.activeOverscroll(
            baseContentHeight: baseContentHeight,
            visibleHeight: visibleHeight,
            lineHeight: lineHeight
        )
    }

    func measuredBaseContentHeight(minimumHeight: CGFloat, forceFullLayout: Bool = false) -> CGFloat {
        let minimumContentHeight = ceil(max(minimumHeight, 0) + (textContainerInset.height * 2))
        guard let textLayoutManager else { return minimumContentHeight }

        // Partial TextKit-2 layout under-measures and oscillates; force full layout only on switch/resize.
        if forceFullLayout {
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        }

        let documentEnd = textLayoutManager.documentRange.endLocation

        // Lay out the last fragment; gives a max-Y fallback if enumerateTextSegments misses it.
        var fragmentMaxY: CGFloat = 0
        var visited = 0
        // Geometry of the fragment containing the document end — the extra line
        // fragment normalization below needs its frame and line boxes.
        var lastFragmentFrame: NSRect = .zero
        var lastFragmentLineBoxes: [CGRect] = []
        textLayoutManager.enumerateTextLayoutFragments(
            from: documentEnd,
            options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if visited == 0 {
                lastFragmentFrame = frame
                lastFragmentLineBoxes = fragment.textLineFragments.map { $0.typographicBounds }
            }
            fragmentMaxY = max(fragmentMaxY, frame.maxY)
            // Trailing block image draws below TextKit's height; count its surface extent so it scrolls.
            let surfaceMaxY = frame.origin.y + fragment.renderingSurfaceBounds.maxY
            if surfaceMaxY > frame.maxY + 8 { fragmentMaxY = max(fragmentMaxY, surfaceMaxY) }
            visited += 1
            return visited < 3
        }

        // End-segment maxY = authoritative document height in TextKit 2.
        let segmentRange = NSTextRange(location: documentEnd)
        textLayoutManager.ensureLayout(for: segmentRange)
        var segmentMaxY: CGFloat = 0
        var segmentMinY: CGFloat = 0
        textLayoutManager.enumerateTextSegments(
            in: segmentRange,
            type: .standard,
            options: .middleFragmentsExcluded
        ) { _, rect, _, _ in
            if rect.maxY >= segmentMaxY {
                segmentMaxY = rect.maxY
                segmentMinY = rect.minY
            }
            return true
        }

        var rawHeight = max(segmentMaxY, fragmentMaxY)

        // With a trailing "\n", the last line is TextKit's extra line fragment.
        // Its metrics follow the final newline's attributes — not the body style a
        // typed line would get — so the measured height would jump on the first
        // typed character. Normalize the empty last line to body metrics.
        if segmentMaxY > 0, let storage = textStorage, storage.mutableString.hasSuffix("\n") {
            let bodyLineHeight = ceil(layoutBridgeDefaultLineHeight(for: baseFont, using: layoutBridge))
                + configuration.paragraph.lineHeightExtraSpacing

            // TextKit omits the final paragraph's paragraphSpacing above the extra
            // line fragment but inserts it once a real character follows — add the
            // missing gap so typing stays height-neutral.
            let ns = storage.mutableString
            let lastParaRange = ns.paragraphRange(for: NSRange(location: ns.length - 1, length: 0))
            let lastParaStyle = storage.attribute(
                .paragraphStyle, at: lastParaRange.location, effectiveRange: nil
            ) as? NSParagraphStyle
            let paragraphSpacing = lastParaStyle?.paragraphSpacing ?? 0
            let prevLineBottom: CGFloat
            if lastFragmentLineBoxes.count >= 2 {
                let secondToLast = lastFragmentLineBoxes[lastFragmentLineBoxes.count - 2]
                prevLineBottom = lastFragmentFrame.minY + secondToLast.maxY
            } else {
                prevLineBottom = lastFragmentFrame.minY
            }
            let appliedGap = max(segmentMinY - prevLineBottom, 0)
            let missingSpacing = max(paragraphSpacing - appliedGap, 0)
            let normalizedEnd = segmentMinY + missingSpacing + bodyLineHeight
            if abs(rawHeight - segmentMaxY) < 0.5 {
                // The extra line itself is the bottom-most content — replace it.
                rawHeight = normalizedEnd
            } else {
                // Something else (e.g. a trailing image surface) reaches lower — keep it.
                rawHeight = max(rawHeight, normalizedEnd)
            }
        }

        return max(ceil(rawHeight + (textContainerInset.height * 2)), minimumContentHeight)
    }

    /// Fixed reading-column width = wrap width + horizontal insets on both sides.
    var readingColumnWidth: CGFloat {
        (configuration.readingWidth ?? 0) + configuration.textInsets.horizontal * 2
    }

    func applyManagedFrameSize(width: CGFloat) {
        let contentHeight = max(ceil(baseContentHeight + activeBottomOverscroll), 0)
        let height: CGFloat
        switch configuration.heightBehavior {
        case .scrolls:
            let scrollViewHeight = enclosingScrollView?.contentView.bounds.height ?? 0
            height = max(contentHeight, scrollViewHeight)
        case .fitsContent:
            height = contentHeight
        }
        // Reading column: the column keeps its fixed wrap width; its centered X is
        // owned by `centerReadingColumn` (driven from the container's restack).
        let targetWidth = configuration.readingWidth != nil ? readingColumnWidth : max(width, 0)
        let targetSize = NSSize(
            width: targetWidth,
            height: height
        )
        guard abs(targetSize.width - frame.size.width) > 0.5 || abs(targetSize.height - frame.size.height) > 0.5 else {
            return
        }
        isApplyingManagedFrameSize = true
        super.setFrameSize(targetSize)
        isApplyingManagedFrameSize = false
        // Tell the container our height changed so it can size itself.
        (superview as? NativeTextViewContainer)?.textViewDidResize()

        // Nudge SwiftUI to re-query sizeThatFits when content height changes outside
        // the text binding (e.g. font-size change).
        if configuration.heightBehavior == .fitsContent {
            enclosingScrollView?.invalidateIntrinsicContentSize()
        }
    }

    /// Re-center the column by moving its X (not resizing it) so it stays smooth during live resize.
    func centerReadingColumn(forClipWidth clipWidth: CGFloat) {
        guard configuration.readingWidth != nil,
              let container = superview as? NativeTextViewContainer else { return }
        if abs(container.frame.size.width - clipWidth) > 0.5 {
            var f = container.frame
            f.size.width = max(clipWidth, 0)
            container.frame = f
        }
        let originX = floor(max(0, (clipWidth - readingColumnWidth) / 2))
        let delta = originX - frame.origin.x
        if abs(delta) > 0.5 {
            setFrameOrigin(NSPoint(x: originX, y: frame.origin.y))
            repositionWideTableOverlaysForWidthChange(insetDelta: delta)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if isApplyingManagedFrameSize {
            super.setFrameSize(newSize)
            return
        }

        guard let scrollView = enclosingScrollView else {
            baseContentHeight = max(newSize.height, 0)
            super.setFrameSize(newSize)
            return
        }

        let widthChanged = abs(newSize.width - frame.size.width) > 0.5
        if widthChanged {
            pendingFullLayoutMeasure = true   // re-wrap → re-measure height against a full layout
            isApplyingManagedFrameSize = true
            super.setFrameSize(NSSize(width: newSize.width, height: frame.size.height))
            isApplyingManagedFrameSize = false
        }

        recalcOverscroll(for: scrollView, targetWidth: newSize.width, debugTag: "setFrameSize")

        // Width change → only rendered table paragraphs need restyling. Their image
        // width can change, and an initially narrow table can become scrollable.
        if widthChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.configuration.readingWidth == nil {
                    self.restyleTableParagraphsForWidthChange()
                }
                self.updateWideTableOverlays()
            }
        }
    }

    /// Restyle only table paragraphs via stamped anchor ranges; avoids re-tokenizing the doc.
    private func restyleTableParagraphsForWidthChange() {
        guard let storage = textStorage,
              let coord = delegate as? NativeTextViewCoordinator else { return }
        var ranges: [NSRange] = []
        var seen: Set<String> = []
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.scrollableBlockFullRange, in: fullRange, options: []) { value, _, _ in
            guard let v = value as? NSValue else { return }
            let r = v.rangeValue
            let key = "\(r.location):\(r.length)"
            if seen.insert(key).inserted { ranges.append(r) }
        }
        guard !ranges.isEmpty else { return }
        coord.restyleParagraphs(ranges, in: self)
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        // Runs from inside AppKit's post-edit processing — outside every
        // sequential span; accumulate so the frame stops hiding it.
        PerfTrace.accumulate("reveal") {
            if suppressAutoRevealOnce {
                suppressAutoRevealOnce = false
                return
            }
            _ = scroll(range: range, position: .nearest)
        }
    }

    @discardableResult
    func scroll(range: NSRange, position: MarkdownScrollPosition) -> Bool {
        let documentLength = (string as NSString).length
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              range.location <= documentLength,
              range.length <= documentLength - range.location,
              let textLayoutManager,
              textLayoutManager.textContentManager != nil else { return false }

        if configuration.heightBehavior == .fitsContent {
            // The inner scroll view has no scrollable range. Propagate the
            // fragment rect to the enclosing page scroller without entering
            // NSTextView's default range-scrolling path.
            guard let rect = rangeRect(for: range, in: textLayoutManager,
                                       documentLength: documentLength) else { return false }
            return propagateCaretRevealToEnclosingScroller(rect: rect)
        }

        guard let scrollView = enclosingScrollView else { return false }
        let clipView = scrollView.contentView
        let topInset = scrollView.contentInsets.top
        let bottomInset = scrollView.contentInsets.bottom
        let usableHeight = max(0, clipView.bounds.height - topInset - bottomInset)

        // Off-screen TextKit 2 fragments can start with estimated Y positions.
        // Scroll to that estimate, lay out the new viewport, then remeasure.
        // Three passes were sufficient for the 10k-word table/image fixture;
        // the bound prevents an unstable layout from spinning the run loop.
        for _ in 0..<3 {
            guard let localRect = rangeRect(for: range, in: textLayoutManager,
                                            documentLength: documentLength) else { return false }
            let targetRect = localRect.offsetBy(dx: frame.origin.x, dy: frame.origin.y)
            let visibleTop = clipView.bounds.minY + topInset
            let visibleBottom = clipView.bounds.maxY - bottomInset
            let targetY: CGFloat

            switch position {
            case .nearest:
                if targetRect.height > usableHeight {
                    // A range taller than the viewport cannot be wholly visible.
                    // Keep an intersecting viewport stable; otherwise reveal its nearest edge.
                    if targetRect.maxY <= visibleTop {
                        targetY = targetRect.maxY - clipView.bounds.height + bottomInset
                    } else if targetRect.minY >= visibleBottom {
                        targetY = targetRect.minY - topInset
                    } else {
                        return true
                    }
                } else {
                    let margin = min(24, (usableHeight - targetRect.height) / 2)
                    if targetRect.minY < visibleTop {
                        targetY = targetRect.minY - topInset - margin
                    } else if targetRect.maxY > visibleBottom {
                        targetY = targetRect.maxY - clipView.bounds.height + bottomInset + margin
                    } else {
                        return true
                    }
                }
            case .center:
                targetY = targetRect.midY - topInset - usableHeight / 2
            }

            let previousY = clipView.bounds.origin.y
            (scrollView as? ClampedScrollView)?.cancelPendingScrollRestore()
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
            (scrollView as? ClampedScrollView)?.clampToInsets()

            textLayoutManager.textViewportLayoutController.layoutViewport()
            if abs(clipView.bounds.origin.y - previousY) < 0.5 { return true }
        }
        return true
    }

    /// The target range in text-view coordinates. TextKit reports segment
    /// geometry in text-container coordinates, so the text-container origin
    /// carries `textContainerInset` into the result.
    private func rangeRect(
        for range: NSRange,
        in textLayoutManager: NSTextLayoutManager,
        documentLength: Int
    ) -> CGRect? {
        let endOffset = range.length == 0
            ? range.location
            : min(range.location + range.length - 1, max(0, documentLength - 1))
        var result = lineRect(
            at: range.location,
            in: textLayoutManager,
            documentLength: documentLength
        )
        if endOffset != range.location,
           let endRect = lineRect(
               at: endOffset,
               in: textLayoutManager,
               documentLength: documentLength
           ) {
            result = result?.union(endRect) ?? endRect
        }
        return result
    }

    /// A caret at document end has no fragment at its exact location, so
    /// fragment lookup steps back while segment lookup still tries the caret.
    private func lineRect(
        at offset: Int,
        in textLayoutManager: NSTextLayoutManager,
        documentLength: Int
    ) -> CGRect? {
        let revealOffset = min(offset, max(0, documentLength - 1))
        guard let contentManager = textLayoutManager.textContentManager,
              let start = contentManager.location(
                textLayoutManager.documentRange.location,
                offsetBy: revealOffset
              ) else { return nil }

        var result: CGRect?
        textLayoutManager.enumerateTextLayoutFragments(
            from: start,
            options: [.ensuresLayout]
        ) { fragment in
            result = fragment.layoutFragmentFrame
            for segmentOffset in [min(offset, documentLength), revealOffset] {
                guard let location = contentManager.location(
                    textLayoutManager.documentRange.location,
                    offsetBy: segmentOffset
                ) else { continue }
                var found = false
                textLayoutManager.enumerateTextSegments(
                    in: NSTextRange(location: location),
                    type: .standard,
                    options: []
                ) { _, frame, _, _ in
                    guard frame.height > 0 else { return false }
                    result = frame
                    found = true
                    return false
                }
                if found { break }
            }
            return false
        }
        return result?.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Walk the view hierarchy above the inner scroll view to find the
    /// enclosing (page-level) scroller and ask it to reveal the caret rect.
    /// Used in `.fitsContent` where the inner scroll view cannot scroll.
    private func propagateCaretRevealToEnclosingScroller(rect: CGRect) -> Bool {
        guard let innerScrollView = enclosingScrollView else { return false }
        // Convert from document-view space (container) to the inner scroll
        // view's coordinate space, then to window, so we can convert into
        // any ancestor we find.
        let container = innerScrollView.documentView ?? self
        let documentRect = rect.offsetBy(dx: frame.origin.x, dy: frame.origin.y)
        let rectInWindow = container.convert(documentRect, to: nil)
        // Walk up past the inner scroll view looking for a parent NSScrollView.
        var view: NSView? = innerScrollView.superview
        while let v = view {
            if let outerScrollView = v as? NSScrollView, outerScrollView !== innerScrollView {
                guard let outerDocView = outerScrollView.documentView else { return false }
                let rectInOuter = outerDocView.convert(rectInWindow, from: nil)
                outerDocView.scrollToVisible(rectInOuter)
                return true
            }
            view = v.superview
        }
        return false
    }

    /// Force TextKit 2 to lay out all fragments within the current visible rect.
    /// Walks from the document head, not the viewport: a fragment's Y is the
    /// sum of the heights above it, so leaving anything above merely estimated
    /// shifts the visible content when it later settles. A viewport-scoped walk
    /// (tried as a perf win) caused content shifts, spurious caret reveals, and
    /// a bistable frame height; steady-state cost here is an enumeration over
    /// already-laid-out fragments.
    func ensureVisibleLayout() {
        guard let tlm = textLayoutManager else { return }
        let visBot = visibleRect.maxY
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
            fragment.layoutFragmentFrame.minY <= visBot
        }
    }
}

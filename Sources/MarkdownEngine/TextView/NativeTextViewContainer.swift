//
//  NativeTextViewContainer.swift
//  MarkdownEngine
//
//  Document view of the editor's scroll view. Hosts the `NativeTextView` and,
//  in reading-column mode, the full-width wide-table overlays around the
//  centered fixed-width column.
//

import AppKit

final class NativeTextViewContainer: NSView {
    weak var textView: NativeTextView?

    private var isRestacking = false

    override var isFlipped: Bool { true }

    var scrollableContentHeight: CGFloat {
        textView?.scrollableContentHeight ?? 0
    }

    func restack(propagateWidth: Bool) {
        guard !isRestacking, let textView else { return }
        isRestacking = true
        defer { isRestacking = false }

        let w = bounds.width
        if propagateWidth {
            if textView.configuration.readingWidth != nil {
                textView.centerReadingColumn(forClipWidth: w)
            } else if abs(textView.frame.width - w) > 0.5 {
                textView.setFrameSize(NSSize(width: w, height: textView.frame.height))
            }
        }
        let x = textView.configuration.readingWidth != nil ? textView.frame.origin.x : 0
        if abs(textView.frame.origin.x - x) > 0.01 {
            textView.setFrameOrigin(NSPoint(x: x, y: 0))
        }
        let viewportH = enclosingScrollView?.contentView.bounds.height ?? 0
        let textHeight = textView.frame.height
        let totalH = (textView.configuration.heightBehavior == .fitsContent) ? textHeight
                                                                              : max(textHeight, viewportH)
        if abs(frame.height - totalH) > 0.5 {
            setFrameSize(NSSize(width: w, height: totalH))
        }
    }

    func textViewDidResize() {
        guard !isRestacking else { return }
        restack(propagateWidth: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        restack(propagateWidth: true)
    }
}

extension NSScrollView {
    var nativeTextView: NativeTextView? {
        (documentView as? NativeTextViewContainer)?.textView
    }
}

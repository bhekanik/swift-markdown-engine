//
//  NativeTextView.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//
//  AppKit `NSTextView` subclass used by the markdown editor. Stored state
//  lives here; behavior is split across `NativeTextView+<Feature>.swift`
//  files in this folder (frame & overscroll, caret workarounds, click remap,
//  paste handling, drag-select boost, task checkbox, spelling policy).
//
//  Bottom-overscroll math lives in `BottomOverscrollPolicy.swift`.
//

import AppKit
import UniformTypeIdentifiers

final class NativeTextView: NSTextView {
    // MARK: Frame & overscroll state
    var baseContentHeight: CGFloat = 0
    var activeBottomOverscroll: CGFloat = 0
    var isApplyingManagedFrameSize = false
    /// Set on switch/resize to force full-layout height measurement until the cascade settles.
    var pendingFullLayoutMeasure = false
    /// Coalesces wide-table overlay updates to once per runloop (resize fires many per frame).
    var pendingWideTableOverlayUpdate = false
    var suppressAutoRevealOnce: Bool = false
    // Set by clickedOnLink during a mouseDown: did the delegate fire (so
    // mouseDown can re-dispatch a click AppKit dropped), and did it navigate
    // (so the pre-click caret is restored — a link click isn't caret placement).
    var linkClickDidFire = false
    var linkClickDidNavigate = false

    // MARK: Configuration
    var configuration: MarkdownEditorConfiguration = .default {
        didSet {
            overscrollPercent = configuration.overscroll.percent
            maxOverscrollPoints = configuration.overscroll.maxPoints
            minOverscrollPoints = configuration.overscroll.minPoints
        }
    }
    var overscrollPercent: CGFloat = MarkdownEditorConfiguration.default.overscroll.percent
    var maxOverscrollPoints: CGFloat = MarkdownEditorConfiguration.default.overscroll.maxPoints
    var minOverscrollPoints: CGFloat = MarkdownEditorConfiguration.default.overscroll.minPoints

    // MARK: Editor wiring
    weak var layoutBridge: LayoutBridge?
    var baseFont: NSFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    // MARK: Caret-workaround state
    var caretIndicatorObservation: NSKeyValueObservation?
    weak var observedCaretIndicator: NSView?
    var isApplyingCaretShift: Bool = false
    /// The indicator's own width, remembered while a block caret is applied so
    /// switching back to `.bar` restores it.
    var caretBarWidth: CGFloat?
    /// Outline of a `.hollow` caret, installed and re-framed by the caret-shape
    /// policy. Retained by the view hierarchy while installed.
    weak var hollowCaretBorder: HollowCaretBorderView?

    // MARK: Drag-select state
    var dragStartMouseScreenLoc: NSPoint?

    // MARK: Placeholder state
    /// Click-through ghost-text label shown while the document is empty;
    /// managed by `NativeTextView+Placeholder.swift`.
    weak var placeholderView: PlaceholderLabelView?

    // MARK: Cursor exclusion
    /// Embedder-supplied predicate that suppresses the I-beam cursor in edit mode.
    /// Called on every mouse-move with the event location in window coordinates.
    /// Return `true` to show the arrow cursor instead of the edit-mode I-beam.
    var isCursorExcluded: ((CGPoint) -> Bool)?

    // MARK: Accessibility projection cache
    var accessibilityProjectionCache: MarkdownAccessibilityProjection?
    var accessibilityProjectionGeneration: UInt64 = .max
    var accessibilityProjectionRawSourceMode = false
    var accessibilityProjectionRegistryFingerprint = ""

    private var textFinderActionResponder: (any MarkdownTextFinderActionResponder)? {
        editorController?.textFinderActionResponder
    }

    var editorController: MarkdownEditorController? {
        (delegate as? NativeTextViewCoordinator)?.editorController
    }

    /// The modal key layer, if the embedder installed one. Composition wins:
    /// while marked text is up the input method owns every key, so this is
    /// `nil` for the duration and the three overrides below fall straight
    /// through to `super`.
    private var activeKeyInterceptor: (any MarkdownKeyInterceptor)? {
        guard !hasMarkedText() else { return nil }
        return editorController?.keyInterceptor
    }

    // MARK: Wide-table overlay state
    /// Live NSScrollView per wide table; keyed by source-ID hash.
    var wideTableOverlays: [Int: WideTableOverlay] = [:]
    /// Persisted horizontal scroll offset per wide table; survives restyles.
    var tableHorizontalScrollOffsets: [Int: CGFloat] = [:]

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Forward appearance changes to the embedder's highlighter via its registered notification.
        if let name = configuration.services.syntaxHighlighter.appearanceDidChangeNotification {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                NotificationCenter.default.post(name: name, object: self)
            }
        }
    }

    // MARK: Keyboard input seam

    override func keyDown(with event: NSEvent) {
        if let interceptor = activeKeyInterceptor,
           interceptor.interceptKeyDown(event, in: self) {
            return
        }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let interceptor = activeKeyInterceptor,
           let text = (string as? NSAttributedString)?.string ?? (string as? String),
           interceptor.interceptInsertText(text, replacementRange: replacementRange, in: self) {
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func doCommand(by selector: Selector) {
        if let interceptor = activeKeyInterceptor,
           interceptor.interceptCommand(selector, in: self) {
            return
        }
        super.doCommand(by: selector)
    }

    // setMarkedText skips textDidChange, so restyle the marked paragraph to apply markdown attrs.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        guard hasMarkedText(),
              let coord = delegate as? NativeTextViewCoordinator else { return }
        let marked = markedRange()
        guard marked.location != NSNotFound, marked.length > 0 else { return }
        // The composition mutated the storage without textDidChange, and
        // shouldChangeTextIn's own parse re-cached the PRE-edit string at the
        // current generation — bump so the restyle below reparses instead of
        // serving that stale document (same-length composition updates).
        coord.parseGeneration &+= 1
        // Census bookkeeping never saw this mutation → next census full-scans.
        coord.backtickCensusNeedsRescan = true
        let nsText = self.string as NSString
        let paragraph = nsText.paragraphRange(for: marked)
        coord.restyleParagraphs([paragraph], in: self)
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? any NSValidatedUserInterfaceItem,
              let action = NSTextFinder.Action(rawValue: item.tag),
              let textFinderActionResponder else {
            super.performTextFinderAction(sender)
            return
        }
        textFinderActionResponder.performTextFinderAction(action)
    }

    func validateTextFinderAction(_ item: any NSValidatedUserInterfaceItem) -> Bool? {
        guard item.action == #selector(performTextFinderAction(_:)),
              let action = NSTextFinder.Action(rawValue: item.tag),
              let textFinderActionResponder else { return nil }
        return textFinderActionResponder.validateTextFinderAction(action)
    }

    deinit { caretIndicatorObservation?.invalidate() }
}

//
//  NativeTextViewWrapper.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Brings the editor into SwiftUI and wires up the text view with the
// right setup, styling, and callbacks.
//
import SwiftUI
import AppKit

@MainActor
private enum ControllerlessRemountRegistry {
    private struct Key: Hashable {
        let remountIdentity: AnyHashable
        let documentId: String
    }

    private final class WeakCoordinator {
        weak var value: NativeTextViewCoordinator?

        init(_ value: NativeTextViewCoordinator) {
            self.value = value
        }
    }

    private static var coordinators: [Key: WeakCoordinator] = [:]
    private static var keysByCoordinator: [ObjectIdentifier: Key] = [:]

    static func register(
        _ coordinator: NativeTextViewCoordinator,
        remountIdentity: AnyHashable?,
        documentId: String,
        active: Bool
    ) {
        unregister(coordinator)
        guard active, let remountIdentity else { return }
        let key = Key(remountIdentity: remountIdentity, documentId: documentId)
        coordinators[key] = WeakCoordinator(coordinator)
        keysByCoordinator[ObjectIdentifier(coordinator)] = key
    }

    static func replacement(for coordinator: NativeTextViewCoordinator) -> NativeTextViewCoordinator? {
        guard let key = keysByCoordinator[ObjectIdentifier(coordinator)],
              let replacement = coordinators[key]?.value,
              replacement !== coordinator else { return nil }
        return replacement
    }

    static func unregister(_ coordinator: NativeTextViewCoordinator) {
        guard let key = keysByCoordinator.removeValue(
            forKey: ObjectIdentifier(coordinator)
        ) else { return }
        if coordinators[key]?.value === coordinator {
            coordinators[key] = nil
        }
    }
}

/// SwiftUI bridge for MarkdownEngine's AppKit-backed editor.
///
/// Wraps a TextKit 2 `NSTextView` inside an `NSScrollView` and exposes a
/// SwiftUI-friendly API of bindings and callback closures. All visual styling and external
/// dependencies are routed through ``MarkdownEditorConfiguration``.
///
/// ### Fit-to-content height
///
/// Set ``MarkdownEditorConfiguration/heightBehavior`` to `.fitsContent` to
/// make the editor report its content height to SwiftUI instead of scrolling
/// internally. Wrap the editor in a `ScrollView` so the page scrolls:
///
/// ```swift
/// ScrollView {
///     NativeTextViewWrapper(
///         text: $text,
///         configuration: .init(heightBehavior: .fitsContent)
///     )
/// }
/// ```
///
/// In `.fitsContent` mode the editor grows/shrinks per keystroke, scroll-
/// wheel events pass through to the enclosing scroller, and caret visibility
/// propagates to the enclosing (page-level) scroll view. The reading column
/// (`readingWidth`) composes naturally. See ``MarkdownEditorConfiguration/HeightBehavior``
/// for the full behavior contract and trade-offs.
public struct NativeTextViewWrapper: NSViewRepresentable {
    public typealias Coordinator = NativeTextViewCoordinator
    public typealias NSViewType = NSScrollView

    /// Two-way binding to the document text.
    @Binding public var text: String
    /// The full editor configuration (theme + services + style toggles). Engine
    /// embedders construct this themselves and pass it in; the wrapper does
    /// not read UserDefaults or know about app-specific colors/services.
    public var configuration: MarkdownEditorConfiguration
    /// Handle on the live editor: external text patches
    /// (``MarkdownEditorController/applyPatch(range:replacement:actionName:registersUndo:)``)
    /// and the underlying `NSTextView` (find, a key layer, typewriter scroll).
    /// The embedder owns the object; the engine attaches on `makeNSView` and
    /// detaches on teardown.
    public var controller: MarkdownEditorController?
    /// PostScript name of the base font used for body text.
    public var fontName: String
    /// Base font size in points. Headings and code blocks are scaled
    /// off this value via ``MarkdownEditorConfiguration``.
    public var fontSize: CGFloat
    /// Opaque document identifier. Each value keeps its own undo stack and
    /// per-document editor state across switching away and back; the undo stack is
    /// dropped only if the document's text changes while it is switched away. Set a
    /// stable, unique value per document so undo stays scoped.
    public var documentId: String
    /// Stable identity for one controller-less editor slot across SwiftUI
    /// remounts. Set this only when replacements with the same value represent
    /// the same live editor, and use a distinct value for every simultaneously
    /// mounted slot. It lets an unflushed local edit move to that exact replacement
    /// without using `documentId` as a global view identity.
    public var controllerlessRemountIdentity: AnyHashable?
    /// When `false` the editor renders read-only with no caret.
    public var isEditable: Bool
    /// Reports whether this wrapper owns its controller's one editor slot.
    /// Called once when the native view is built and again when that state
    /// changes. A refused second view reports `nil` and never observes the
    /// first view's attachment lifecycle.
    public var onAttachmentChange: ((NSTextView?) -> Void)?
    /// Reports one completed native edit in UTF-16 file coordinates.
    /// Multi-step smart-input transformations and ambiguous composition
    /// batches are omitted so embedders can treat every callback as exact.
    public var onTextMutation: ((MarkdownTextMutation) -> Void)?
    /// Build the editor's right-click menu (the engine ships no menu). Receives the default
    /// NSMenu + the current selection range; return the menu to display (or unchanged).
    public var onBuildContextMenu: ((NSMenu, NSRange) -> NSMenu)?
    /// Fires when the set of visible code blocks changes, so embedders can
    /// overlay copy buttons (see ``CodeBlockButton``).
    public var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?
    /// Fires after the user toggles any of the three spell/grammar/auto-correction
    /// menu items. Embedders persist the policy and pass it back via
    /// ``MarkdownEditorConfiguration/spellChecking`` on next launch.
    public var onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)?

    /// Ghost text shown at the first-line position while the document is empty;
    /// the first typed character hides it.
    public var placeholder: NSAttributedString?

    /// documentIds whose scroll offset to keep; others are forgotten. `nil` keeps all.
    public var retainedScrollDocumentIds: Set<String>?

    /// Scroll memory that outlives the editor. The engine's own offsets live on the
    /// coordinator, so an embedder that unmounts the editor entirely — routing to a
    /// different screen and back — loses them; these hand the offsets somewhere that
    /// survives. `persist` is called on switch-away AND on teardown, `restore` when a
    /// document becomes current (nil opens at the top). Both are asked at call time,
    /// so the embedder's own retention rules can see changes made on the way out.
    public var onPersistScrollOffset: ((String, CGFloat) -> Void)?
    public var restoreScrollOffset: ((String) -> CGFloat?)?

    /// Embedder-supplied predicate that suppresses the I-beam cursor in edit mode.
    /// Called on mouse-move with the event location in window coordinates.
    /// Return `true` to show the arrow cursor instead of the I-beam.
    public var isCursorExcluded: ((CGPoint) -> Bool)?

    public init(
        text: Binding<String>,
        configuration: MarkdownEditorConfiguration = .default,
        controller: MarkdownEditorController? = nil,
        fontName: String = "SF Pro",
        fontSize: CGFloat = 16,
        documentId: String = "default",
        controllerlessRemountIdentity: AnyHashable? = nil,
        isEditable: Bool = true,
        onAttachmentChange: ((NSTextView?) -> Void)? = nil,
        onTextMutation: ((MarkdownTextMutation) -> Void)? = nil,
        onBuildContextMenu: ((NSMenu, NSRange) -> NSMenu)? = nil,
        onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)? = nil,
        onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)? = nil,
        placeholder: NSAttributedString? = nil,
        retainedScrollDocumentIds: Set<String>? = nil,
        onPersistScrollOffset: ((String, CGFloat) -> Void)? = nil,
        restoreScrollOffset: ((String) -> CGFloat?)? = nil,
        isCursorExcluded: ((CGPoint) -> Bool)? = nil
    ) {
        self._text = text
        self.configuration = configuration
        self.controller = controller
        self.fontName = fontName
        self.fontSize = fontSize
        self.documentId = documentId
        self.controllerlessRemountIdentity = controllerlessRemountIdentity
        self.isEditable = isEditable
        self.onAttachmentChange = onAttachmentChange
        self.onTextMutation = onTextMutation
        self.onBuildContextMenu = onBuildContextMenu
        self.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        self.onSpellCheckingPolicyChanged = onSpellCheckingPolicyChanged
        self.placeholder = placeholder
        self.retainedScrollDocumentIds = retainedScrollDocumentIds
        self.onPersistScrollOffset = onPersistScrollOffset
        self.restoreScrollOffset = restoreScrollOffset
        self.isCursorExcluded = isCursorExcluded
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard configuration.heightBehavior == .fitsContent,
              let container = nsView.documentView as? NativeTextViewContainer else {
            return nil
        }
        let width = proposal.width ?? nsView.contentView.bounds.width
        // Height is taken from the most recent layout pass rather than re-measured
        // at `proposal.width`. Re-measuring TextKit content at a speculative width
        // inside sizeThatFits risks layout loops (TextKit relayout → frame change →
        // sizeThatFits re-entry) and is expensive for large documents. In practice
        // SwiftUI calls sizeThatFits after the view has already been laid out at the
        // proposed width, and `invalidateIntrinsicContentSize` in
        // `applyManagedFrameSize` ensures SwiftUI re-queries after every width-driven
        // relayout, so the returned height stays correct.
        return CGSize(width: width, height: container.scrollableContentHeight)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ClampedScrollView()
        scrollView.fitsContent = configuration.heightBehavior == .fitsContent
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = configuration.heightBehavior.wantsVerticalScroller(for: configuration.scrollers)
        scrollView.hasHorizontalScroller = configuration.scrollers.hasHorizontalScroller
        scrollView.autohidesScrollers = configuration.scrollers.autohidesScrollers
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: configuration.safeAreaInsets.top,
            left: configuration.safeAreaInsets.leading,
            bottom: configuration.safeAreaInsets.bottom,
            right: configuration.safeAreaInsets.trailing
        )

        // With a controller, the DOCUMENT owns the content storage and this
        // view gets its own layout manager and container on it, so the view can
        // later be pointed at a different document by moving that manager (see
        // `MarkdownEditorController.adopt`). Without one, NSTextView
        // auto-initialises its own TextKit 2 stack via init(frame:).
        //
        // A controller drives exactly one view. Whether this one gets it is
        // settled HERE, before any storage is touched: joining the document's
        // storage and then discovering the controller is taken would leave a
        // second layout manager laying out a document this view is not attached
        // to, and `textView.string = text` below would have overwritten it.
        let owner = controller?.isAttached == true ? nil : controller
        if controller != nil, owner == nil {
            NSLog("MarkdownEngine: a view was built while its controller already had one, "
                  + "so it shows its text on a storage of its own and reaches nothing. A "
                  + "controller drives exactly one view — give a second window its own "
                  + "MarkdownEditorController and forward onTextMutation into its applyPatch.")
        }
        let textView: NativeTextView
        if let controller = owner {
            let layoutManager = NSTextLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            layoutManager.textContainer = container
            controller.textContentStorage.addTextLayoutManager(layoutManager)
            textView = NativeTextView(frame: .zero, textContainer: container)
        } else {
            textView = NativeTextView(frame: .zero)
        }

        guard let textContainer = textView.textContainer,
              let textLayoutManager = textView.textLayoutManager else {
            fatalError("NSTextView did not create a TextKit 2 stack on this OS version")
        }
        textContainer.lineFragmentPadding = 0
        if let readingWidth = configuration.readingWidth {
            // Fix wrap width at readingWidth so text never re-wraps on resize; only the column's position moves.
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(width: readingWidth, height: .greatestFiniteMagnitude)
        } else {
            textContainer.widthTracksTextView = true
        }
        textView.textContainerInset = NSSize(
            width: configuration.textInsets.horizontal,
            height: configuration.textInsets.vertical
        )
        textContainer.heightTracksTextView = false

        let layoutDelegate = MarkdownLayoutManagerDelegate()
        context.coordinator.layoutDelegate = layoutDelegate
        textLayoutManager.delegate = layoutDelegate
        textView.configuration = configuration
        textView.overscrollPercent = configuration.overscroll.percent
        textView.maxOverscrollPoints = configuration.overscroll.maxPoints
        textView.minOverscrollPoints = configuration.overscroll.minPoints
        context.coordinator.configuration = configuration
        textView.insertionPointColor = configuration.theme.bodyText
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = true
        textView.string = text
        textView.delegate = context.coordinator
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.postsFrameChangedNotifications = true
        // Width and origin are driven by the container document view (see below).
        textView.autoresizingMask = []
        textView.backgroundColor = .clear
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.baseFont = font
        textView.allowsUndo = configuration.undo == .engine
        textView.isCursorExcluded = isCursorExcluded
        textView.isAutomaticSpellingCorrectionEnabled = configuration.spellChecking.automaticSpellingCorrection
        textView.isContinuousSpellCheckingEnabled = configuration.spellChecking.continuousSpellChecking
        textView.isGrammarCheckingEnabled = configuration.spellChecking.grammarChecking
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = false
        if configuration.rawSourceMode {
            context.coordinator.enterRawSourceMode(textView)
        }
        if #available(macOS 15.1, *) {
            // `.limited` = the Writing Tools popover panel; `.complete` = the inline
            // experience that morphs the text with an animation. We use `.limited` so
            // rewrites/proofread land in the popover (no in-text animation) — it also
            // sidesteps the inline-rewrite flicker that dims text below the selection.
            textView.writingToolsBehavior = .limited
        }
        // Create TextKit 2 layout bridge
        let bridge = LayoutBridge(textLayoutManager)
        context.coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge

        // The document view is ALWAYS a container (`NativeTextViewContainer`) hosting
        // the text view and, in reading-column mode, the full-width wide-table
        // overlays around the centered fixed-width column.
        let vpSize = scrollView.contentView.bounds.size
        let container = NativeTextViewContainer(frame: NSRect(origin: .zero, size: vpSize))
        container.autoresizingMask = [.width]
        container.textView = textView
        let initialWidth = configuration.readingWidth != nil ? textView.readingColumnWidth : vpSize.width
        textView.frame = NSRect(x: 0, y: 0, width: initialWidth, height: textView.frame.height)
        container.addSubview(textView)
        scrollView.documentView = container
        // Force full-document layout at init so paragraph heights are known
        // upfront; otherwise TextKit 2 viewport layout causes scroll drift.
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.clampToInsets()
        scrollView.reflectScrolledClipView(scrollView.contentView)

        context.coordinator.textView = textView
        context.coordinator.editorController = owner
        if let owner, owner.attach(
                textView: textView,
                coordinator: context.coordinator,
                notifyEmbedder: false
            ) {
            context.coordinator.pendingAttachmentAnnouncement = owner
            context.coordinator.hasPendingAttachmentAnnouncement = true
            context.coordinator.requestedControllerWhileDetached = nil
            context.coordinator.isDetachedFromDocument = false
        } else if controller != nil {
            // Refused above. Ask to be handed the controller when it frees up:
            // SwiftUI builds a remount's replacement before dismantling the
            // original and then sends this view no further update pass, so
            // re-checking on the next pass would never happen.
            context.coordinator.editorController = nil
            context.coordinator.requestedControllerWhileDetached = controller
            context.coordinator.isDetachedFromDocument = true
            controller?.awaitSlot(context.coordinator)
            context.coordinator.reportAttachment(nil)
        } else {
            context.coordinator.editorController = nil
            context.coordinator.requestedControllerWhileDetached = nil
            context.coordinator.isDetachedFromDocument = false
            context.coordinator.hasPendingAttachmentAnnouncement = true
            ControllerlessRemountRegistry.register(
                context.coordinator,
                remountIdentity: controllerlessRemountIdentity,
                documentId: documentId,
                active: true
            )
        }
        context.coordinator.onTextMutation = onTextMutation
        context.coordinator.onBuildContextMenu = onBuildContextMenu
        context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange

        textView.recalcOverscroll(for: scrollView)
        textView.setPlaceholder(placeholder)
        // Initial reading-column centering; the resize observer below handles later changes.
        if configuration.readingWidth != nil {
            textView.centerReadingColumn(forClipWidth: scrollView.contentView.bounds.width)
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        var lastObservedViewportWidth = scrollView.contentView.bounds.width
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: nil) { _ in
            // AppKit posts NSView geometry notifications during main-thread view mutations.
            MainActor.assumeIsolated {
                // Refresh code-block overlays only on real viewport width changes, not on TextKit height-only echoes during typing.
                let newWidth = scrollView.contentView.bounds.width
                if abs(newWidth - lastObservedViewportWidth) > 0.5 {
                    lastObservedViewportWidth = newWidth
                    // Re-center the column by position (no redraw) so it stays smooth during live resize.
                    // Read readingWidth from the live textView.configuration (a class, captured by
                    // reference) instead of the struct `configuration` captured by value at
                    // makeNSView time — the embedder may change readingWidth between updates.
                    if textView.configuration.readingWidth != nil {
                        textView.centerReadingColumn(forClipWidth: newWidth)
                    }
                    context.coordinator.didEnsureLayoutForCurrentDocument = false
                    context.coordinator.updateCodeBlockSelection(textView: textView)
                }
                // Only react with overscroll recalc when the viewport itself resizes
                // (window resize). Without this guard, TextKit-induced frame changes echo
                // back here and re-trigger recalcOverscroll, causing a 149pt height
                // oscillation after clicks. Compare the CONTAINER (the document view) height
                // to the viewport — it tracks the viewport for short docs.
                guard let container = scrollView.documentView as? NativeTextViewContainer else { return }
                // Read heightBehavior from the live textView.configuration (a class,
                // captured by reference) — not the struct `configuration` captured by
                // value at makeNSView time. Without this, a runtime .fitsContent→.scrolls
                // switch leaves this closure permanently early-returning, so viewport-
                // resize-driven recalcOverscroll is skipped → stale overscroll.
                if textView.configuration.heightBehavior == .fitsContent {
                    // In .fitsContent the container is content-tall (not viewport-tall),
                    // so the container-vs-viewport guard below is always true — which
                    // would fire recalcOverscroll on every clip-view frame change. Only
                    // width changes need a re-measure (text re-wraps); height-only
                    // changes are already handled by the width-change block above.
                    return
                }
                guard abs(container.frame.height - scrollView.contentView.bounds.height) > 1 else { return }
                textView.recalcOverscroll(for: scrollView)
                scrollView.clampToInsets()
            }
        }
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { _ in
            MainActor.assumeIsolated {
                textView.ensureVisibleLayout()
                if context.coordinator.isWritingToolsActive {
                    context.coordinator.fixWritingToolsChildWindowIfNeeded(textView: textView)
                }
                scrollView.clampToInsets()
                context.coordinator.updateCodeBlockSelection(textView: textView)
            }
        }
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.nativeTextView else {
            return
        }
        if context.coordinator.controllerlessRemountIdentity != controllerlessRemountIdentity {
            context.coordinator.invalidatePendingBindingWrite()
            context.coordinator.controllerlessRemountIdentity = controllerlessRemountIdentity
        }
        ControllerlessRemountRegistry.register(
            context.coordinator,
            remountIdentity: controllerlessRemountIdentity,
            documentId: documentId,
            active: controller == nil
                && context.coordinator.requestedControllerWhileDetached == nil
        )
        let isNodeSwitch = context.coordinator.documentId != documentId
        // This snapshot chooses text authority, not admission. A callback may
        // free the target, but its document storage remains authoritative.
        let targetControllerHadAuthoritativeText = controller?.isAttached == true
            && controller?.textView !== textView
        var textToSynchronize = text
        var correctedInexactBindingText: String?
        let currentController = context.coordinator.editorController
            ?? context.coordinator.requestedControllerWhileDetached
        let waitingControllerBecameAvailable =
            context.coordinator.requestedControllerWhileDetached === controller
            && controller?.isAttached == false
        let controllerChanged = currentController !== controller || waitingControllerBecameAvailable
        let pendingBindingWriteIsAuthoritative: Bool
        if !isNodeSwitch, !controllerChanged,
           let pendingText = context.coordinator.pendingBindingWriteAuthority(
               from: textView,
               bindingText: text
           ) {
            textToSynchronize = pendingText
            pendingBindingWriteIsAuthoritative = true
        } else {
            pendingBindingWriteIsAuthoritative = false
        }
        if let staleBinding = context.coordinator.staleBindingAfterControllerTakeover {
            if !controllerChanged,
               staleBinding.controller == controller.map(ObjectIdentifier.init),
               staleBinding.documentId == documentId {
                if text == staleBinding.text {
                    textToSynchronize = textView.string
                } else {
                    context.coordinator.staleBindingAfterControllerTakeover = nil
                }
            } else {
                context.coordinator.staleBindingAfterControllerTakeover = nil
            }
        }
        var shouldReportDetachedIncoming = false

        // Scroll persistence belongs to the SwiftUI wrapper, not the attached
        // document, so its current closures are always safe to refresh here.
        context.coordinator.onPersistScrollOffset = onPersistScrollOffset
        context.coordinator.restoreScrollOffset = restoreScrollOffset
        // Attachment and edit callbacks belong to the CURRENT document. During
        // a controller swap the outgoing attachment must report through its old
        // closures; the incoming closures are installed after detach, before
        // the new document can publish selection-derived state.
        if !controllerChanged {
            context.coordinator.onAttachmentChange = onAttachmentChange
            context.coordinator.onTextMutation = onTextMutation
            context.coordinator.onBuildContextMenu = onBuildContextMenu
            context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        }

        // Drop remembered offsets for documents no longer retained (always keep
        // the current one). Only rebuilds the dict when something must go.
        if let retained = retainedScrollDocumentIds {
            let needsPrune = context.coordinator.scrollOffsets.keys.contains { key in
                key != documentId && !retained.contains(key)
            }
            if needsPrune {
                context.coordinator.scrollOffsets = context.coordinator.scrollOffsets.filter {
                    $0.key == documentId || retained.contains($0.key)
                }
            }
            // Evict undo stacks + content snapshots for documents no longer
            // retained (keep the current one); clear actions before dropping.
            let staleUndoKeys = Set(context.coordinator.undoManagers.keys)
                .union(context.coordinator.undoContentSnapshots.keys)
                .filter { key in
                    key != documentId && key != "__default__" && !retained.contains(key)
                }
            for key in staleUndoKeys {
                context.coordinator.undoManagers[key]?.removeAllActions()
                context.coordinator.undoManagers.removeValue(forKey: key)
                context.coordinator.undoContentSnapshots.removeValue(forKey: key)
            }
        }

        let wtActive: Bool = {
            if #available(macOS 15.0, *), textView.isWritingToolsActive { return true }
            return context.coordinator.isWritingToolsActive
        }()

        if wtActive && isNodeSwitch {
            // User switched files while Writing Tools was active — discard the
            // WT session so it doesn't overwrite the wrong node.
            // Keep wtStartDocumentId so textViewWritingToolsDidEnd can detect the
            // node mismatch and discard the results.
            context.coordinator.isWritingToolsActive = false
        } else if wtActive {
            // WT active on the same node — don't interfere with the session.
            // Note: this skips the heightBehavior sync below, so a heightBehavior
            // change while Writing Tools is active won't take effect until the
            // session ends. WT sessions are transient and height-mode switches
            // during one are not a supported use case.
            return
        }

        textView.isCursorExcluded = isCursorExcluded
        textView.setPlaceholder(placeholder)
        // The embedder can hand this view a different controller between
        // passes — showing a different document in the same window. Re-pointing
        // the attachment is not enough: the view lays out through its layout
        // manager, and that is still bound to the old document's content
        // storage, so the window keeps showing the old document and every edit
        // lands in it. Detach from the old controller (which drops the layout
        // manager off its storage), reserve the new controller, then move the
        // manager and force a full rebuild — the storage under the view is a
        // different document now, so nothing about the old one is still true.
        if controllerChanged {
            context.coordinator.staleBindingAfterControllerTakeover = nil
            textToSynchronize = text
            if let previous = context.coordinator.editorController {
                // Remember where this window was in the OUTGOING document, so
                // coming back to it lands the reader where they left.
                context.coordinator.selectionByDocument[ObjectIdentifier(previous)] =
                    textView.selectedRange()
                // The reset below is transfer bookkeeping, not a user
                // selection. Do not publish code-block selection state for the
                // outgoing document while the host is replacing its callback.
                context.coordinator.onCodeBlockSelectionChange = nil
                // The first reset must happen while the outgoing storage is
                // still attached. Resetting after detach asks TextKit 2 for a
                // document range through a layout manager with no content
                // manager, which logs and leaves the selection undefined.
            }
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            context.coordinator.reportAttachment(nil)
            context.coordinator.editorController?.detach(textView: textView)
            context.coordinator.onAttachmentChange = onAttachmentChange
            context.coordinator.resetAttachmentReportForNewObserver()
            context.coordinator.onTextMutation = onTextMutation
            context.coordinator.onBuildContextMenu = onBuildContextMenu
            context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
            // A selection from the old document can be out of range for the new
            // one, and the next attribute write (`textView.font = font`, below)
            // makes AppKit fix attributes over the selected range — which traps
            // in `ensureAttributesAreFixedInRange`.
            //
            // Zeroed TWICE, deliberately. Once here, while the view still has
            // storage to accept it; and again after the move, because detaching
            // the layout manager leaves the view with no content manager and
            // the selection it reads back afterwards is neither zero nor in
            // range (measured: 1235 against a length of 0).
            context.coordinator.editorController = nil
            context.coordinator.requestedControllerWhileDetached = nil
            if let layoutManager = textView.textLayoutManager,
               layoutManager.textContentManager == nil {
                // Detaching the controller also detached its document storage.
                // A controller-less wrapper needs storage of its own to remain editable.
                NSTextContentStorage().addTextLayoutManager(layoutManager)
            }
            if let controller {
                if controller.attach(
                    textView: textView,
                    coordinator: context.coordinator,
                    notifyEmbedder: false
                ) {
                    context.coordinator.editorController = controller
                    if let layoutManager = textView.textLayoutManager {
                        controller.adopt(layoutManager: layoutManager)
                    }
                    if targetControllerHadAuthoritativeText {
                        textToSynchronize = textView.string
                        if textToSynchronize != text {
                            context.coordinator.staleBindingAfterControllerTakeover = (
                                ObjectIdentifier(controller),
                                documentId,
                                text
                            )
                        }
                    }
                    context.coordinator.pendingAttachmentAnnouncement = controller
                    context.coordinator.hasPendingAttachmentAnnouncement = true
                    context.coordinator.isDetachedFromDocument = false
                } else {
                    context.coordinator.requestedControllerWhileDetached = controller
                    context.coordinator.isDetachedFromDocument = true
                    shouldReportDetachedIncoming = true
                    controller.awaitSlot(
                        context.coordinator,
                        announceOnImmediateHandoff: false
                    )
                }
            } else {
                context.coordinator.pendingAttachmentAnnouncement = nil
                context.coordinator.hasPendingAttachmentAnnouncement = true
                context.coordinator.isDetachedFromDocument = false
            }
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            context.coordinator.didInitialFormatting = false
            context.coordinator.didEnsureLayoutForCurrentDocument = false
            context.coordinator.invalidateParseCache()
            context.coordinator.pendingSelectionRestore = controller.map { ObjectIdentifier($0) }
        }
        context.coordinator.configuration.undo = configuration.undo
        textView.configuration.undo = configuration.undo
        textView.allowsUndo = configuration.undo == .engine
        // Sync heightBehavior across all three layers (scroll view, text view,
        // coordinator) so a runtime switch fully reconfigures.
        let heightBehaviorChanged = textView.configuration.heightBehavior != configuration.heightBehavior
        if let clamped = nsView as? ClampedScrollView {
            clamped.fitsContent = configuration.heightBehavior == .fitsContent
        }
        textView.configuration.heightBehavior = configuration.heightBehavior
        context.coordinator.configuration.heightBehavior = configuration.heightBehavior
        let desiredVerticalScroller = configuration.heightBehavior.wantsVerticalScroller(for: configuration.scrollers)
        if nsView.hasVerticalScroller != desiredVerticalScroller {
            nsView.hasVerticalScroller = desiredVerticalScroller
        }
        if nsView.hasHorizontalScroller != configuration.scrollers.hasHorizontalScroller {
            nsView.hasHorizontalScroller = configuration.scrollers.hasHorizontalScroller
        }
        if nsView.autohidesScrollers != configuration.scrollers.autohidesScrollers {
            nsView.autohidesScrollers = configuration.scrollers.autohidesScrollers
        }
        // When heightBehavior changes at runtime, re-measure and re-report so the
        // view reconfigures immediately (inflation toggles, overscroll zeroing).
        if heightBehaviorChanged {
            textView.recalcOverscroll(for: nsView)
            (nsView as? ClampedScrollView)?.clampToInsets()
            nsView.invalidateIntrinsicContentSize()
        }
        // A presentation flip is applied in one piece further down, where the
        // rebuild it needs already happens — see `applyPresentationChange`.
        let rawSourceModeChanged = context.coordinator.configuration.rawSourceMode != configuration.rawSourceMode
        // Sync the input-behavior toggles (auto-close pairs, list helpers).
        // The keystroke handlers read textView.configuration live, but only
        // makeNSView used to write it — an embedder settings change was inert
        // until the editor was rebuilt. Plain assignment: a tiny value struct,
        // and no rebuild is needed for it to take effect.
        textView.configuration.lists = configuration.lists
        context.coordinator.configuration.lists = configuration.lists
        // Sync registered extensions (inline spans + fenced blocks). A change alters
        // the GRAMMAR (tokens differ under the new registry), so the coordinator's parsed
        // cache must drop before the restyle — the parse-layer memos invalidate
        // themselves via the registry fingerprint.
        let newExtensionFingerprint = configuration.extensionRegistry.fingerprint
        if newExtensionFingerprint != context.coordinator.configuration.extensionRegistry.fingerprint {
            context.coordinator.applyExtensionChange(configuration.extensions, in: textView)
        }
        // Reading column centers by POSITION (container subview), so the text inset is constant.
        let desiredTextInset = NSSize(
            width: configuration.textInsets.horizontal,
            height: configuration.textInsets.vertical
        )
        if abs(textView.textContainerInset.width - desiredTextInset.width) > 0.5
            || abs(textView.textContainerInset.height - desiredTextInset.height) > 0.5 {
            textView.textContainerInset = desiredTextInset
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
        // Keep the caret ink the selection handler resolved (an extension span
        // can invert it); a plain bodyText reset here stomps it on every pass.
        textView.insertionPointColor = isEditable
            ? (context.coordinator.resolvedCaretColor ?? context.coordinator.configuration.theme.bodyText)
            : .clear
        let fontChanged = (context.coordinator.fontName != fontName) || (context.coordinator.fontSize != fontSize)
        // `rawSourceModeChanged` is named here rather than left to a
        // `didInitialFormatting = false` set forty lines above: an embedder
        // whose two presentations share a font changes nothing else about this
        // pass, and the switch was dropped on the floor.
        if context.coordinator.didInitialFormatting
            && context.coordinator.lastSyncedText == textToSynchronize
            && !fontChanged
            && !controllerChanged
            && !rawSourceModeChanged {
            return
        }
        if fontChanged {
            context.coordinator.didInitialFormatting = false
        }
        if isNodeSwitch {
            // Save the outgoing document's scroll position — unless it just left
            // the retained set, in which case let it reset to top next time.
            if let outgoingId = context.coordinator.documentId {
                let offsetY = nsView.contentView.bounds.origin.y
                if retainedScrollDocumentIds?.contains(outgoingId) ?? true {
                    context.coordinator.scrollOffsets[outgoingId] = offsetY
                }
                // The embedder's store applies its own retention — it is asked live,
                // so it can see what the snapshot above was taken too early to know.
                let incomingController = context.coordinator.editorController
                let incomingRevision = incomingController?.documentRevision
                let incomingTextBeforePersistence = textView.string
                onPersistScrollOffset?(outgoingId, offsetY)
                if controllerChanged,
                   incomingController === controller,
                   context.coordinator.editorController === incomingController,
                   incomingController?.documentRevision != incomingRevision {
                    if let incomingController,
                       let incomingRevision,
                       let records = incomingController.documentMutationRecords(after: incomingRevision),
                       let replayed = Self.replayDocumentMutations(records, onto: textToSynchronize) {
                        textToSynchronize = replayed
                    } else if !targetControllerHadAuthoritativeText {
                        let fallbackPatch = MarkdownTextPatch.diff(
                            from: incomingTextBeforePersistence,
                            to: textView.string
                        )
                        if let merged = Self.apply(fallbackPatch, onto: textToSynchronize) {
                            textToSynchronize = merged
                            correctedInexactBindingText = merged
                        } else {
                            textToSynchronize = textView.string
                        }
                    } else {
                        textToSynchronize = textView.string
                    }
                    if let controller, textToSynchronize != text {
                        context.coordinator.staleBindingAfterControllerTakeover = (
                            ObjectIdentifier(controller),
                            documentId,
                            text
                        )
                    }
                }
            }
            // Snapshot the outgoing document's content so a later
            // switch-back can detect a file rewritten while it was backgrounded.
            // `lastSyncedText` still holds the outgoing content here.
            if let outgoingId = context.coordinator.documentId {
                context.coordinator.undoContentSnapshots[outgoingId] = context.coordinator.lastSyncedText
            }
            // Per-document undo: close the OUTGOING document's open coalescing group
            // (while its manager is still active), then switch the active documentId so
            // `undoManager(for:)` starts vending the INCOMING document's own manager. We
            // no longer clear undo here — that `removeAllActions()` is what killed Cmd+Z
            // across a file switch.
            textView.breakUndoCoalescing()
            context.coordinator.documentId = documentId
            context.coordinator.armScrollRestore(for: documentId)
            // Drop the incoming document's undo stack if its text changed while
            // switched away — its recorded ranges are now stale.
            context.coordinator.invalidateUndoIfContentDiverged(
                for: documentId,
                incomingText: textToSynchronize
            )
            context.coordinator.didInitialFormatting = false
            context.coordinator.didEnsureLayoutForCurrentDocument = false
            // Drop old document's wide-table overlays synchronously.
            textView.removeAllWideTableOverlays()
            // Park at top during the rebuild; the new document's own saved offset
            // (if any) is restored after its height is known (see below).
            nsView.contentView.scroll(to: NSPoint(x: 0, y: -nsView.contentInsets.top))
            nsView.reflectScrolledClipView(nsView.contentView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }

        // An external `text` change on the SAME document — a remote edit, a
        // history navigation, a canonicalisation — is an EDIT, not a new
        // document. Splice it in through the engine's own edit path so the
        // caret and the scroll offset survive; `textView.string =` below would
        // reset the selection to {0, 0}. Falls through to the rebuild when the
        // change is too large to be an edit.
        if !isNodeSwitch, !rawSourceModeChanged, !fontChanged, !controllerChanged,
           context.coordinator.didInitialFormatting {
            if pendingBindingWriteIsAuthoritative {
                return
            }
            let spliceResult = context.coordinator.spliceExternalText(
                textToSynchronize,
                in: textView,
                publishesMutation: false
            )
            switch spliceResult {
            case .applied, .invalidated:
                textView.recalcOverscroll(for: nsView)
                (nsView as? ClampedScrollView)?.clampToInsets()
                context.coordinator.onTextMutation = onTextMutation
                context.coordinator.onBuildContextMenu = onBuildContextMenu
                context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
                return
            case .declined:
                break
            }
        }

        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.baseFont = font
        // Skip on switch: textView.string still holds the OUTGOING doc here, so the "?"
        // tag would force a full ensureLayout of the doc about to be discarded (~274ms /
        // 7714 frags @346k). recalcOverscroll#2 after the rebuild measures the new doc;
        // scroll is parked at top so clampToInsets below stays in range. Non-switch
        // updates (font change, typing) must keep the forced full layout.
        if !isNodeSwitch {
            textView.recalcOverscroll(for: nsView)
        }
        (nsView as? ClampedScrollView)?.clampToInsets()

        // Sync coordinator's font fields BEFORE the rebuild so the helper
        // reads the current values from the View struct.
        context.coordinator.fontName = fontName
        context.coordinator.fontSize = fontSize
        if rawSourceModeChanged {
            context.coordinator.applyPresentationChange(
                to: configuration.rawSourceMode,
                in: textView,
                documentId: documentId,
                text: textToSynchronize,
                preservingPendingBindingWrite: pendingBindingWriteIsAuthoritative
            )
        } else {
            context.coordinator.rebuildTextStorageAndStyle(
                textView,
                from: textToSynchronize,
                invalidateLayout: isNodeSwitch,
                preservingPendingBindingWrite: pendingBindingWriteIsAuthoritative
            )
        }
        textView.recalcOverscroll(for: nsView)
        (nsView as? ClampedScrollView)?.clampToInsets()
        // The new document is laid out, so its remembered caret is meaningful
        // again — clamped, because the document it was recorded in may have
        // been longer than this one.
        if !context.coordinator.isDetachedFromDocument,
           let restoreKey = context.coordinator.pendingSelectionRestore {
            let remembered = context.coordinator.selectionByDocument[restoreKey]
                ?? NSRange(location: 0, length: 0)
            textView.setSelectedRange(
                remembered.clamped(toLength: (textView.string as NSString).length))
            context.coordinator.pendingSelectionRestore = nil
        }
        // Height is measured now, so restore the saved offset; clampToInsets keeps
        // it in range if the document got shorter. Latched rather than gated on
        // `isNodeSwitch`, because a remount is not a switch and its first pass still
        // carries the embedder's empty buffer — the clamp would pull it back to top.
        if context.coordinator.pendingScrollRestoreDocumentId == documentId {
            context.coordinator.pendingScrollRestoreAttempts -= 1
            let saved = restoreScrollOffset?(documentId) ?? context.coordinator.scrollOffsets[documentId]
            if let savedY = saved {
                nsView.contentView.scroll(to: NSPoint(x: nsView.contentView.bounds.origin.x, y: savedY))
                nsView.reflectScrolledClipView(nsView.contentView)
                (nsView as? ClampedScrollView)?.clampToInsets()
                // A zero-height viewport cannot contradict any offset: with no range to
                // clamp against the scroll is taken verbatim, so this is true for EVERY
                // value — it says the offset was set, not that it survived. Believing it
                // retires the latch before the geometry exists; the first real layout
                // then clamps the reader back to the top and nothing is left to correct
                // it. Measured on a remount after routing away: saved=201 actual=201
                // landed=true viewportH=0.
                let measured = nsView.contentView.bounds.height > 0
                let landed = measured && abs(nsView.contentView.bounds.origin.y - savedY) < 1
                // Also give up once the real content has had its chance, landed or
                // not: an armed latch outliving the document's arrival lets a much
                // later unrelated pass — ⌘+/⌘−, the raw-source toggle, a buffer
                // reload — scroll the reader away from wherever they went.
                // The "content has arrived" give-up needs the same proof: a non-empty
                // buffer laid out into nothing has not had its chance either.
                if !measured {
                    // No geometry on this tick: hand it to the scroll view, which applies
                    // it from its own layout. Retiring the latch here is safe because the
                    // offset is no longer waiting on another update pass — and those stop
                    // coming (measured: two passes, both viewportH=0, then nothing, with
                    // the latch left armed forever and teardown refusing to save).
                    (nsView as? ClampedScrollView)?.armScrollRestore(to: savedY)
                    context.coordinator.pendingScrollRestoreDocumentId = nil
                } else if landed || !text.isEmpty || context.coordinator.pendingScrollRestoreAttempts <= 0 {
                    context.coordinator.pendingScrollRestoreDocumentId = nil
                }
            } else {
                context.coordinator.pendingScrollRestoreDocumentId = nil
            }
        }
        // Document rebuilds bypass textDidChange — re-derive emptiness here.
        textView.refreshPlaceholderVisibility()
        DispatchQueue.main.async {
            guard textView.textLayoutManager?.textContentManager != nil else { return }
            context.coordinator.updateCodeBlockSelection(textView: textView)
        }

        context.coordinator.onTextMutation = onTextMutation
        context.coordinator.onBuildContextMenu = onBuildContextMenu
        context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        context.coordinator.didInitialFormatting = true
        if let correctedInexactBindingText {
            context.coordinator.scheduleBindingWriteBack(
                correctedInexactBindingText,
                from: textView,
                replacing: text
            )
        }
        ControllerlessRemountRegistry.register(
            context.coordinator,
            remountIdentity: controllerlessRemountIdentity,
            documentId: documentId,
            active: controller == nil
                && context.coordinator.requestedControllerWhileDetached == nil
        )
        if shouldReportDetachedIncoming && context.coordinator.isDetachedFromDocument {
            context.coordinator.reportAttachment(nil)
        }
        context.coordinator.reportPendingAttachment(textView)
    }

    private static func replayDocumentMutations(
        _ records: [MarkdownDocumentMutationRecord],
        onto text: String
    ) -> String? {
        // A changed revision without a record cannot prove how the source changed.
        guard !records.isEmpty else { return nil }
        let result = NSMutableString(string: text)
        for record in records {
            guard let mutation = record.mutation else { return nil }
            guard apply(
                MarkdownTextPatch(range: mutation.range, replacement: mutation.replacement),
                to: result
            ) else {
                return nil
            }
        }
        return result as String
    }

    private static func apply(_ patch: MarkdownTextPatch, onto text: String) -> String? {
        let result = NSMutableString(string: text)
        return apply(patch, to: result) ? result as String : nil
    }

    private static func apply(_ patch: MarkdownTextPatch, to text: NSMutableString) -> Bool {
        let length = text.length
        guard patch.range.location >= 0,
              patch.range.location <= length,
              patch.range.length >= 0,
              patch.range.length <= length - patch.range.location else {
            return false
        }
        text.replaceCharacters(in: patch.range, with: patch.replacement)
        return true
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = NativeTextViewCoordinator(
            text: $text,
            fontName: fontName,
            fontSize: fontSize
        )
        coordinator.documentId = documentId
        coordinator.controllerlessRemountIdentity = controllerlessRemountIdentity
        coordinator.onPersistScrollOffset = onPersistScrollOffset
        coordinator.onAttachmentChange = onAttachmentChange
        coordinator.onTextMutation = onTextMutation
        coordinator.restoreScrollOffset = restoreScrollOffset
        // Seeding documentId above means the first update pass is not a switch, so
        // arm the restore here or a remount would always open at the top.
        coordinator.armScrollRestore(for: documentId)
        coordinator.configuration = configuration
        coordinator.editorController = controller
        coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        coordinator.userPrefersContinuousSpellChecking = configuration.spellChecking.continuousSpellChecking
        coordinator.userPrefersGrammarChecking = configuration.spellChecking.grammarChecking
        coordinator.userPrefersAutomaticSpellingCorrection = configuration.spellChecking.automaticSpellingCorrection
        coordinator.onSpellCheckingPolicyChanged = onSpellCheckingPolicyChanged
        return coordinator
    }

    /// The editor can go away without a document switch — an embedder routing to a
    /// different screen — and that is the only moment left to record where the
    /// reader was; the coordinator's own offsets die with it.
    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let replacement = ControllerlessRemountRegistry.replacement(for: coordinator) {
            coordinator.transferPendingBindingWrite(to: replacement)
        } else {
            coordinator.invalidatePendingBindingWrite()
        }
        ControllerlessRemountRegistry.unregister(coordinator)
        coordinator.reportAttachment(nil)
        coordinator.onAttachmentChange = nil
        if let textView = coordinator.textView {
            coordinator.editorController?.detach(textView: textView)
        }
        // A restore still pending means the reader was never put back where they
        // were — recording the current offset would overwrite the good one with
        // the mid-load position.
        guard let documentId = coordinator.documentId,
              coordinator.pendingScrollRestoreDocumentId == nil else { return }
        coordinator.onPersistScrollOffset?(documentId, nsView.contentView.bounds.origin.y)
    }
}

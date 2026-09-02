//
//  NativeTextViewCoordinator.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Keeps the editor in sync while you type, updating formatting, selections,
// and other editing behavior in one place.
import AppKit
import os
import SwiftUI

final class ProposalTextStorageRegistration {
    let storage: NSTextStorage
    let generation: OSAllocatedUnfairLock<UInt64>
    private var notificationToken: NSObjectProtocol?

    init(storage: NSTextStorage) {
        self.storage = storage
        let generation = OSAllocatedUnfairLock(initialState: UInt64(0))
        self.generation = generation
        notificationToken = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { notification in
            guard let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            generation.withLock { $0 &+= 1 }
        }
    }

    func invalidate() {
        guard let notificationToken else { return }
        NotificationCenter.default.removeObserver(notificationToken)
        self.notificationToken = nil
    }

    isolated deinit {
        invalidate()
    }
}

final class ProposalTextStorageObservation {
    let registration: ProposalTextStorageRegistration
    let startingGeneration: UInt64

    var storage: NSTextStorage { registration.storage }
    var didProcessCharacterEdit: Bool {
        registration.generation.withLock { $0 } != startingGeneration
    }

    init(registration: ProposalTextStorageRegistration) {
        self.registration = registration
        startingGeneration = registration.generation.withLock { $0 }
    }
}

/// `NSTextViewDelegate` that bridges ``NativeTextViewWrapper`` and the
/// underlying `NSTextView`.
///
/// The coordinator is created automatically by SwiftUI; embedders never
/// construct one directly. Behaviors that don't fit in the main file live
/// in extensions (Autocorrect, CodeBlocks, Find,
/// Notifications, Restyling, TextDelegate, WritingTools).
public final class NativeTextViewCoordinator: NSObject, NSTextViewDelegate {
    var documentId: String?
    var controllerlessRemountIdentity: AnyHashable?
    /// Remembered scroll offset (`bounds.origin.y`) per `documentId` — saved on
    /// switch-away, restored on switch-back. Dies with the coordinator, so an
    /// embedder that unmounts the editor supplies the two closures below instead.
    var scrollOffsets: [String: CGFloat] = [:]
    /// Embedder-owned scroll memory that outlives this coordinator. `persist` is
    /// also called from `dismantleNSView`; `restore` returning nil opens at top.
    var onPersistScrollOffset: ((String, CGFloat) -> Void)?
    var restoreScrollOffset: ((String) -> CGFloat?)?
    /// documentId whose remembered offset still has to be applied, and how many
    /// update passes it may keep trying. A remount is not a switch (SwiftUI seeds
    /// `documentId` in `makeCoordinator`) and its first pass still carries the
    /// embedder's empty buffer, so the offset can only land on a later pass. The
    /// budget bounds it: a document that really got shorter must not keep yanking.
    var pendingScrollRestoreDocumentId: String?
    var pendingScrollRestoreAttempts = 0
    /// Per-`documentId` undo manager. AppKit reuses a single `NSTextView` across
    /// all open documents, so its built-in (view-wide) undo manager would mix
    /// files together. Keying a manager on the current document gives each file
    /// its own undo stack that survives switching away and back. Vended through
    /// the `undoManager(for:)` delegate method; pruned alongside `scrollOffsets`.
    var undoManagers: [String: UndoManager] = [:]
    /// Per-`documentId` content snapshot taken on switch-away. On
    /// switch-back a mismatch means the file was rewritten while backgrounded, so
    /// the now-stale undo stack is dropped. Pruned alongside `undoManagers`.
    var undoContentSnapshots: [String: String] = [:]
    @Binding var text: String
    var fontName: String
    var fontSize: CGFloat
    var styleRevision: String?
    var configuration: MarkdownEditorConfiguration = .default {
        didSet {
            subscribeToBusNotifications(replacing: oldValue.services.bus)
            subscribeToAppearanceNotification()
            // Precompiled registry for the per-keystroke parse path — deriving
            // it from the configuration on every keystroke would rebuild the
            // delimiter arrays + fingerprint string each time.
            cachedExtensionRegistry = configuration.extensionRegistry
        }
    }
    /// Memoized `configuration.extensionRegistry` (see didSet).
    var cachedExtensionRegistry: ExtensionRegistry = .empty
    private var busObservers: [NSObjectProtocol] = []
    private var registeredAppearanceObserverName: Notification.Name?
    weak var textView: NSTextView?
    var activeProposalTextStorageObservations: [ProposalTextStorageObservation] = []
    /// The view managed through the public AppKit adopt/detach lifecycle.
    /// SwiftUI owns its separate dismantle path.
    weak var appKitAdoptedTextView: NSTextView?
    var layoutBridge: LayoutBridge?
    var layoutDelegate: MarkdownLayoutManagerDelegate?
    /// Embedder handle for external patches and the text-view seam. Weak: the
    /// embedder owns it and outlives the editor.
    weak var editorController: MarkdownEditorController?
    /// The requested document while its controller is still driving another view.
    /// Kept separate so this view can stay isolated yet accept the later handoff.
    weak var requestedControllerWhileDetached: MarkdownEditorController?
    var onAttachmentChange: ((NSTextView?) -> Void)?
    /// Reserved controller whose public attachment callbacks must wait until
    /// `updateNSView` has synchronized storage, styling, and host callbacks.
    weak var pendingAttachmentAnnouncement: MarkdownEditorController?
    var hasPendingAttachmentAnnouncement = false
    private weak var reportedAttachedTextView: NSTextView?
    private var didReportAttachment = false

    /// Publish this wrapper's attachment state without conflating it with
    /// another wrapper using the same controller.
    func reportAttachment(_ textView: NSTextView?) {
        if didReportAttachment {
            if let textView, reportedAttachedTextView === textView { return }
            if textView == nil, reportedAttachedTextView == nil { return }
        }
        didReportAttachment = true
        reportedAttachedTextView = textView
        onAttachmentChange?(textView)
    }

    func resetAttachmentReportForNewObserver() {
        didReportAttachment = false
        reportedAttachedTextView = nil
    }

    func reportPendingAttachment(_ textView: NSTextView) {
        guard hasPendingAttachmentAnnouncement else { return }
        hasPendingAttachmentAnnouncement = false
        guard let controller = pendingAttachmentAnnouncement else {
            guard editorController == nil, !isDetachedFromDocument else { return }
            reportAttachment(textView)
            return
        }
        pendingAttachmentAnnouncement = nil
        guard editorController === controller,
              controller.textView === textView else { return }
        controller.notifyEmbedderOfAttachment(textView)
        guard editorController === controller,
              controller.textView === textView else {
            if editorController === controller {
                editorController = nil
                requestedControllerWhileDetached = nil
                isDetachedFromDocument = true
            }
            return
        }
        reportAttachment(textView)
    }

    /// Where this VIEW was in each document it has shown, keyed by controller
    /// identity. A window swapped between documents puts the reader back.
    var selectionByDocument: [ObjectIdentifier: NSRange] = [:]
    /// Set while a controller swap is in flight; consumed once the new
    /// document has been rebuilt and its length is known.
    var pendingSelectionRestore: ObjectIdentifier?
    /// True while this view was built for a document another view already had.
    ///
    /// It is showing its text on a TextKit stack of its own and speaks for
    /// nobody: its edits are not the document's edits, so they must not reach
    /// the embedder's binding or its edit feed. Cleared when the requested
    /// controller frees or the wrapper selects another available target.
    var isDetachedFromDocument = false
    var onTextMutation: ((MarkdownTextMutation) -> Void)?
    private struct DeferredPublicMutation {
        let mutation: MarkdownTextMutation
        let callback: ((MarkdownTextMutation) -> Void)?
    }
    private var deferredPublicMutations: [DeferredPublicMutation]?
    private var isFlushingPublicMutations = false

    func beginDeferringPublicMutations() {
        if deferredPublicMutations == nil {
            deferredPublicMutations = []
        }
    }

    func flushDeferredPublicMutations() {
        guard !isFlushingPublicMutations, deferredPublicMutations != nil else { return }
        isFlushingPublicMutations = true
        var index = 0
        // A callback may apply another batch. Its storage lands immediately,
        // but its callback joins the tail so listeners receive every admitted
        // pre-edit batch mutation before mutations addressed to the new text.
        while let mutations = deferredPublicMutations, index < mutations.count {
            let deferred = mutations[index]
            index += 1
            deferred.callback?(deferred.mutation)
        }
        deferredPublicMutations = nil
        isFlushingPublicMutations = false
    }

    func deferPublicMutation(_ mutation: MarkdownTextMutation) -> Bool {
        guard deferredPublicMutations != nil else { return false }
        deferredPublicMutations?.append(DeferredPublicMutation(
            mutation: mutation,
            callback: onTextMutation
        ))
        return true
    }
    /// Embedder hook to build the right-click menu (the engine ships none). Gets the
    /// default menu + current selection range, returns the menu to show.
    var onBuildContextMenu: ((NSMenu, NSRange) -> NSMenu)?
    var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?
    var didInitialFormatting: Bool = false
    /// One-shot guard so `updateCodeBlockSelection` only forces a full-document layout once per document.
    var didEnsureLayoutForCurrentDocument: Bool = false
    /// True only while `rebuildTextStorageAndStyle` runs. Assigning `textView.string`
    /// and transferring the styled string both re-enter `textViewDidChangeSelection`
    /// synchronously; the rebuild already produces the full styling + selection state,
    /// so that re-entrant pass is pure waste (measured 71ms on a 346k note). Mirrors
    /// the `didEnsureLayoutForCurrentDocument` suppression pattern.
    var isRebuildingDocument = false
    var isNotifyingTextFinderClientStringChange = false
    /// Batch admission already notified Finder before any requested patch lands.
    /// Suppress the second notification while applying that admitted batch.
    private var textFinderInvalidationSuppressionDepth = 0
    var suppressesTextFinderInvalidation: Bool {
        textFinderInvalidationSuppressionDepth > 0
    }
    func beginSuppressingTextFinderInvalidation() {
        textFinderInvalidationSuppressionDepth += 1
    }
    func endSuppressingTextFinderInvalidation() {
        textFinderInvalidationSuppressionDepth = max(0, textFinderInvalidationSuppressionDepth - 1)
    }
    struct ProgrammaticBatchMutation {
        let mutation: MarkdownTextMutation
        let documentLength: Int
    }
    var activeProgrammaticBatchMutations: [ProgrammaticBatchMutation]?
    private var mutationTransactionDepth = 0
    var rejectsReentrantMutation: Bool {
        mutationTransactionDepth > 0
    }
    func beginMutationTransaction() {
        mutationTransactionDepth += 1
    }
    func endMutationTransaction() {
        mutationTransactionDepth = max(0, mutationTransactionDepth - 1)
    }
    // Consumed at delegate entry, before Finder or service callbacks run, so
    // reentrant proposals cannot inherit the batch commit's one admission.
    private var hasAdmittedMutationProposal = false
    func admitNextMutationProposal() {
        hasAdmittedMutationProposal = true
    }
    func consumeAdmittedMutationProposal() -> Bool {
        guard hasAdmittedMutationProposal else { return false }
        hasAdmittedMutationProposal = false
        return true
    }
    func discardAdmittedMutationProposal() {
        hasAdmittedMutationProposal = false
    }
    func recordAndPublishCompletedMutation(
        _ mutation: MarkdownTextMutation?,
        mutationDelta: Int,
        documentLength: Int
    ) {
        if let batch = activeProgrammaticBatchMutations {
            for item in batch {
                editorController?.recordDocumentMutation(
                    item.mutation,
                    mutationDelta: (item.mutation.replacement as NSString).length
                        - item.mutation.range.length,
                    documentLength: item.documentLength
                )
                publish(item.mutation)
            }
            return
        }
        editorController?.recordDocumentMutation(
            mutation,
            mutationDelta: mutationDelta,
            documentLength: documentLength
        )
        if let mutation {
            publish(mutation)
        }
    }
    /// Main-queue Binding writes must not outlive a newer edit or rebuild.
    private var bindingWritebackGeneration: UInt64 = 0
    private struct PendingBindingWrite {
        let generation: UInt64
        let textView: ObjectIdentifier
        let controller: ObjectIdentifier?
        let documentId: String?
        let previousText: String
        let text: String
    }
    private var pendingBindingWrite: PendingBindingWrite?
    var lastSyncedText: String

    func updateTextBinding(_ binding: Binding<String>) {
        _text = binding
    }

    func scheduleBindingWriteBack(_ newText: String, from textView: NSTextView) {
        bindingWritebackGeneration &+= 1
        let generation = bindingWritebackGeneration
        pendingBindingWrite = PendingBindingWrite(
            generation: generation,
            textView: ObjectIdentifier(textView),
            controller: editorController.map(ObjectIdentifier.init),
            documentId: documentId,
            previousText: text,
            text: newText
        )
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView else { return }
            _ = self.commitPendingBindingWrite(
                generation: generation,
                from: textView,
                bindingText: self.text
            )
        }
    }

    func commitPendingBindingWrite(
        generation: UInt64? = nil,
        from textView: NSTextView,
        bindingText: String
    ) -> String? {
        guard let pending = validPendingBindingWrite(
            generation: generation,
            from: textView,
            bindingText: bindingText
        ) else { return nil }
        pendingBindingWrite = nil
        bindingWritebackGeneration &+= 1
        lastSyncedText = pending.text
        if !bindingText.hasSameUTF16(as: pending.text) {
            writeBindingBack(pending.text)
        }
        return pending.text
    }

    func pendingBindingWriteAuthority(
        from textView: NSTextView,
        bindingText: String
    ) -> String? {
        validPendingBindingWrite(from: textView, bindingText: bindingText)?.text
    }

    func transferPendingBindingWrite(to replacement: NativeTextViewCoordinator) {
        guard let textView,
              let pending = validPendingBindingWrite(
                  from: textView,
                  bindingText: text
              ),
              let replacementTextView = replacement.textView,
              replacement.documentId == pending.documentId,
              replacement.text.hasSameUTF16(as: pending.previousText),
              replacementTextView.string.hasSameUTF16(as: pending.previousText) else {
            invalidatePendingBindingWrite()
            return
        }
        let selection = textView.selectedRange()
        invalidatePendingBindingWrite()
        replacement.rebuildTextStorageAndStyle(
            replacementTextView,
            from: pending.text
        )
        replacementTextView.setSelectedRange(
            selection.clamped(toLength: (pending.text as NSString).length)
        )
        replacement.scheduleBindingWriteBack(pending.text, from: replacementTextView)
    }

    func invalidatePendingBindingWrite() {
        pendingBindingWrite = nil
        bindingWritebackGeneration &+= 1
    }

    private func validPendingBindingWrite(
        generation: UInt64? = nil,
        from textView: NSTextView,
        bindingText: String
    ) -> PendingBindingWrite? {
        guard let pending = pendingBindingWrite,
              generation == nil || generation == pending.generation,
              pending.generation == bindingWritebackGeneration else { return nil }
        guard
              pending.textView == ObjectIdentifier(textView),
              self.textView === textView,
              pending.controller == editorController.map(ObjectIdentifier.init),
              pending.documentId == documentId,
              textView.string.hasSameUTF16(as: pending.text),
              bindingText.hasSameUTF16(as: pending.previousText)
                  || bindingText.hasSameUTF16(as: pending.text),
              !isDetachedFromDocument else {
            pendingBindingWrite = nil
            bindingWritebackGeneration &+= 1
            return nil
        }
        return pending
    }

    func synchronizeWithoutBindingWrite(
        _ newText: String,
        preservingPendingBindingWrite: Bool = false
    ) {
        if preservingPendingBindingWrite { return }
        invalidatePendingBindingWrite()
        lastSyncedText = newText
    }
    /// A controller takeover can expose newer document storage than the
    /// embedder's binding. Ignore only that captured stale snapshot until the
    /// binding advances; a different value remains a supported external edit.
    var staleBindingAfterControllerTakeover: (
        controller: ObjectIdentifier,
        documentId: String,
        text: String
    )?
    /// Finder invalidation is public and synchronous, so a programmatic edit
    /// can re-enter through a controller patch before its own scope unwinds.
    private var programmaticEditDepth = 0
    var isProgrammaticEdit: Bool {
        get { programmaticEditDepth > 0 }
        set {
            if newValue {
                programmaticEditDepth += 1
            } else {
                programmaticEditDepth = max(0, programmaticEditDepth - 1)
            }
        }
    }
    var isWritingToolsActive: Bool = false
    var wtStartDocumentId: String?
    var wtSourceSnapshot: String?
    var wtStartDocumentRevision: UInt64?
    var wtStartDocumentPublishedDelta: Int = 0
    var wtStartDocumentLength: Int = 0
    weak var wtChildWindow: NSWindow?
    var wtInitialChildOrigin: CGPoint?
    var wtInitialSelectionRange: NSRange?
    enum WTMode { case unknown, proofread, rewrite }
    var wtDetectedMode: WTMode = .unknown
    var wtUndoObserverTokens: [NSObjectProtocol] = []
    var wtUndoneDuringSession: Bool = false
    var wtPostUndoSnapshot: String?
    var activeTokenIndices: Set<Int> = []
    var previousActiveTokenIndices: Set<Int> = []
    var previousBacktickCount: Int = 0
    /// Backtick census baseline captured in shouldChangeTextIn: the pre-edit
    /// window count around the proposed edit, so textDidChange can update the
    /// census from the edited window alone instead of rescanning the document.
    var pendingBacktickWindow: (location: Int, oldLength: Int, oldCount: Int)?
    /// Whether the PRE-edit text around the pending edit touched a registered
    /// extension block fence — captured in shouldChangeTextIn so a DELETED
    /// fence still forces the full restyle in textDidChange.
    var pendingExtFenceTouched = false
    /// Set in shouldChangeTextIn when an edit changes list-leading syntax or a
    /// line break, which can shift every following ordered number; consumed
    /// once in textDidChange to restyle the affected ordered run.
    var pendingListStructureEdit = false
    /// Set when the storage mutated without the census bookkeeping seeing it
    /// (IME composition) — forces the next census back to a full scan.
    var backtickCensusNeedsRescan = false
    /// DEBUG-only sampling counter for verifying the incremental census.
    var backtickVerifyCounter: UInt = 0
    /// Incremental parse state for this editor (buffer + blocks + tokens
    /// evolve together under the edit descriptor).
    let parseState = DocumentParseState()
    /// Monotonic stamp for fresh ParsedDocument builds (see ParsedDocument.version).
    var parsedDocumentVersion: UInt64 = 0
    /// Single-slot memo for computeActiveTokenIndices — it runs up to three
    /// times per keystroke on identical inputs (pre-edit ask, selection
    /// change, textDidChange). Pure function of (version, selection, suppressed).
    var activeTokenMemo: (version: UInt64, selection: NSRange, suppressed: Bool, result: Set<Int>)?

    /// Text length after the previous textDidChange — yields the edit's
    /// length delta without retaining the previous text.
    var previousDisplayLength: Int = -1
    var pendingEditedRange: NSRange? = nil
    /// Exact pre-edit descriptor paired with `pendingEditedRange`. It is
    /// published only when one accepted proposal produces the change event.
    var pendingTextMutation: MarkdownTextMutation?
    /// Retains the real delta when several proposals collapse into one change
    /// event and no single range can reproduce it.
    var pendingTextMutationStartLength: Int?
    /// Proposed-edit cycles since the last completed textDidChange. Exactly 1
    /// means the hoisted editedRange/lengthDelta describe a single tracked
    /// edit and incremental fast paths may trust them.
    var pendingEditCount = 0
#if DEBUG
    /// Diagnostic: whether the last completed textDidChange ran with a
    /// trusted single-edit descriptor (fast paths). Read by tests.
    var debugLastEditWasTrusted: Bool? = nil
#endif
    var pendingPreEditActiveTokenIndices: Set<Int>? = nil
    var previousCaretLocation: Int? = nil
    /// Full previous selection — selection-revealed task syntax needs to know
    /// when the selection SPAN changed, not just its location (shift-extends
    /// keep the anchor put while newly covering lines).
    var previousSelectedRange: NSRange? = nil
    /// Drag-select suppressed a restyle; replayed on the next non-drag selection change.
    var needsRestyleAfterDrag = false
    /// Caret color resolved at the last selection change (an extension span can
    /// invert the ink under the caret). `updateNSView` re-applies it instead of
    /// resetting to `theme.bodyText`, which would stomp it on any SwiftUI pass;
    /// nil = no span, use the theme.
    var resolvedCaretColor: NSColor?

    var cachedCodeBlockTokens: [(index: Int, token: MarkdownToken)] = []
    /// Dedupe key of the last emitted code-block selections — identical
    /// (parse version, scroll, width, active-code set) means identical output,
    /// so the second per-keystroke invocation can skip the geometry work.
    var lastCodeSelKey: (UInt64, CGFloat, CGFloat, Set<Int>)?
    var cachedParsedText: String?
    var cachedParsedDocument: ParsedDocument?
    /// Monotonic edit counter: bumped whenever the text storage can have
    /// changed. Lets `parsedDocument` return cache hits in O(1) instead of an
    /// O(doc) string compare. Any code that mutates the storage directly
    /// (bypassing shouldChangeText/textDidChange) must bump this.
    var parseGeneration: UInt64 = 0
    var cachedParseGeneration: UInt64 = .max
    var cachedParsedLength: Int = -1
    // Skip spellcheck property setters when the state wouldn't change.
    var cachedSpellingDisabled: Bool?

    // Mirrors the user's last-known preference for each spell/grammar toggle.
    // `updateAutocorrectSettings` reads these when restoring outside a
    // suppress zone, so caret movement no longer clobbers a manual "off".
    var userPrefersContinuousSpellChecking: Bool = true
    var userPrefersGrammarChecking: Bool = true
    var userPrefersAutomaticSpellingCorrection: Bool = true
    var rawSourceInputSettingsSnapshot: RawSourceInputSettings?

    struct RawSourceInputSettings {
        let automaticQuoteSubstitution: Bool
        let automaticDashSubstitution: Bool
        let automaticTextReplacement: Bool
        let automaticSpellingCorrection: Bool
        let smartInsertDelete: Bool

        init(textView: NSTextView) {
            automaticQuoteSubstitution = textView.isAutomaticQuoteSubstitutionEnabled
            automaticDashSubstitution = textView.isAutomaticDashSubstitutionEnabled
            automaticTextReplacement = textView.isAutomaticTextReplacementEnabled
            automaticSpellingCorrection = textView.isAutomaticSpellingCorrectionEnabled
            smartInsertDelete = textView.smartInsertDeleteEnabled
        }
    }

    /// Fires after the user toggles a spell/grammar/auto-correction menu item.
    /// Embedders persist the returned policy (e.g. to `UserDefaults`) and feed
    /// it back via ``MarkdownEditorConfiguration/spellChecking`` on next launch.
    var onSpellCheckingPolicyChanged: ((SpellCheckingPolicy) -> Void)?

    var currentSpellCheckingPolicy: SpellCheckingPolicy {
        SpellCheckingPolicy(
            continuousSpellChecking: userPrefersContinuousSpellChecking,
            grammarChecking: userPrefersGrammarChecking,
            automaticSpellingCorrection: userPrefersAutomaticSpellingCorrection
        )
    }

    /// Called from ``NativeTextView`` toggle overrides after `super` flips the
    /// underlying property. Snapshots the text view's state, refreshes the
    /// cache so the next caret move doesn't immediately overwrite it, and
    /// notifies the embedder.
    func didToggleSpellCheckingPolicy(textView: NSTextView) {
        userPrefersContinuousSpellChecking = textView.isContinuousSpellCheckingEnabled
        userPrefersGrammarChecking = textView.isGrammarCheckingEnabled
        userPrefersAutomaticSpellingCorrection = textView.isAutomaticSpellingCorrectionEnabled
        // Invalidate the "didn't change" short-circuit so the next selection
        // update re-applies the preferences cleanly.
        cachedSpellingDisabled = nil
        onSpellCheckingPolicyChanged?(currentSpellCheckingPolicy)
    }

    struct ParsedDocument {
        let tokens: [MarkdownToken]
        /// The block list the tokens were derived from — handed to the restyle
        /// so DocumentAST.parse consumes it instead of re-deriving blocks
        /// (full buffer re-extraction + memcmp per keystroke).
        let blocks: [Block]
        let codeTokens: [MarkdownToken]
        let tableTokens: [MarkdownToken]
        /// Code-block tokens with their index into `tokens` (active-token
        /// checks need the original index) — collected in the same single
        /// classification pass instead of a per-call full-token filter.
        let codeBlockTokensWithIndices: [(index: Int, token: MarkdownToken)]
        /// Per-kind indexed token arrays for the styler's NSImage passes, built
        /// in the same single classification pass so the passes iterate small
        /// scope-sliced arrays instead of walking every document token.
        let classified: MarkdownStyler.ClassifiedStyleTokens
        /// Bumped only when a FRESH parse builds this document — cache-hit
        /// returns share the version, so (version, selection, suppressed) is
        /// an exact memo key for pure derivations like active-token indices.
        let version: UInt64
    }

    init(text: Binding<String>,
         fontName: String,
         fontSize: CGFloat) {
        _text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.lastSyncedText = text.wrappedValue
        super.init()
        // Init + didSet share this helper so the observer tracks whichever service is current.
        subscribeToAppearanceNotification()
    }

    func beginObservingProposalTextStorage(
        _ storage: NSTextStorage
    ) -> ProposalTextStorageObservation {
        let registration = activeProposalTextStorageObservations.first {
            $0.storage === storage
        }?.registration ?? ProposalTextStorageRegistration(storage: storage)
        let observation = ProposalTextStorageObservation(registration: registration)
        activeProposalTextStorageObservations.append(observation)
        return observation
    }

    func endObservingProposalTextStorage(_ observation: ProposalTextStorageObservation) {
        guard let index = activeProposalTextStorageObservations.lastIndex(where: {
            $0 === observation
        }) else { return }
        activeProposalTextStorageObservations.remove(at: index)
        guard !activeProposalTextStorageObservations.contains(where: {
            $0.storage === observation.storage
        }) else { return }
        observation.registration.invalidate()
    }

    /// (Re)register the syntax-highlighter appearance observer; idempotent and unsubscribes on nil.
    private func subscribeToAppearanceNotification() {
        let target = configuration.services.syntaxHighlighter.appearanceDidChangeNotification
        if registeredAppearanceObserverName == target { return }
        if let current = registeredAppearanceObserverName {
            NotificationCenter.default.removeObserver(self, name: current, object: nil)
        }
        registeredAppearanceObserverName = nil
        guard let name = target else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange(_:)),
            name: name,
            object: nil
        )
        registeredAppearanceObserverName = name
    }

    /// Subscribe to whichever bus notification names the current configuration
    /// supplies. Removes any previous subscriptions first so that swapping
    /// configurations at runtime doesn't double-fire handlers.
    private func subscribeToBusNotifications(replacing previous: MarkdownEditorBus) {
        busObservers.forEach(NotificationCenter.default.removeObserver(_:))
        busObservers.removeAll(keepingCapacity: true)

        let bus = configuration.services.bus
        let center = NotificationCenter.default

        if let name = bus.applyBoldRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // OperationQueue.main is the runtime guarantee for this synchronous actor hop.
                MainActor.assumeIsolated { self?.handleBoldNotification() }
            })
        }
        if let name = bus.applyItalicRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleItalicNotification() }
            })
        }
        if let name = bus.applyHeadingRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let level = notification.userInfo?["level"] as? Int else { return }
                MainActor.assumeIsolated { self?.handleHeadingNotification(level: level) }
            })
        }
        if let name = bus.applyHighlightRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleHighlightNotification() }
            })
        }
        if let name = bus.applyStrikethroughRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleStrikethroughNotification() }
            })
        }
        if let name = bus.applyInlineCodeRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleInlineCodeNotification() }
            })
        }
        if let name = bus.applyBlockquoteRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleBlockquoteNotification() }
            })
        }
        if let name = bus.applyUnorderedListRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleUnorderedListNotification() }
            })
        }
        if let name = bus.applyOrderedListRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleOrderedListNotification() }
            })
        }
        if let name = bus.applyLinkRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let url = notification.userInfo?["url"] as? String ?? ""
                MainActor.assumeIsolated { self?.handleLinkNotification(url: url) }
            })
        }
        if let name = bus.applyCodeBlockRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleCodeBlockNotification() }
            })
        }
        if let name = bus.applyHorizontalRuleRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleHorizontalRuleNotification() }
            })
        }
        if let name = bus.applyImageRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let url = notification.userInfo?["url"] as? String ?? ""
                MainActor.assumeIsolated { self?.handleImageNotification(url: url) }
            })
        }
        if let name = bus.findScrollToRange {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let info = notification.userInfo,
                      let currentIndex = info["currentIndex"] as? Int,
                      let allRanges = info["allRanges"] as? [NSRange] else { return }
                let range = info["range"] as? NSRange
                MainActor.assumeIsolated {
                    self?.handleFindScrollToRange(
                        range: range,
                        currentIndex: currentIndex,
                        allRanges: allRanges
                    )
                }
            })
        }
        if let name = bus.findClearHighlights {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleFindClearHighlights() }
            })
        }
        if let name = bus.findQuery {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let query = notification.userInfo?["query"] as? String else { return }
                let currentIndex = notification.userInfo?["currentIndex"] as? Int ?? 0
                MainActor.assumeIsolated {
                    self?.handleFindQuery(query: query, currentIndex: currentIndex)
                }
            })
        }
        if let name = bus.replaceCurrent {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let info = notification.userInfo,
                      let query = info["query"] as? String,
                      let replacement = info["replacement"] as? String else { return }
                let currentIndex = info["currentIndex"] as? Int ?? 0
                MainActor.assumeIsolated {
                    self?.handleReplaceCurrent(
                        query: query,
                        replacement: replacement,
                        currentIndex: currentIndex
                    )
                }
            })
        }
        if let name = bus.replaceAll {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let info = notification.userInfo,
                      let query = info["query"] as? String,
                      let replacement = info["replacement"] as? String else { return }
                MainActor.assumeIsolated {
                    self?.handleReplaceAll(query: query, replacement: replacement)
                }
            })
        }
    }

    // Find-in-document highlight handlers live in
    // `NativeTextViewCoordinator+Find.swift`.

    /// Four passes: a remount needs two (empty buffer, then the real content).
    func armScrollRestore(for documentId: String) {
        pendingScrollRestoreDocumentId = documentId
        pendingScrollRestoreAttempts = 4
    }

    // Methods are split across the following extensions:
    //   - +TextDelegate    — NSTextViewDelegate hot path
    //   - +Restyling       — restyle pipeline + parsedDocument cache
    //   - +CodeBlocks      — copy-button overlay
    //   - +Find            — find-in-document highlights
    //   - +Notifications   — bus + appearance bridge
    //   - +Autocorrect     — spell/grammar/quote toggles
    //   - +WritingTools    — macOS 15+ Writing Tools session

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        busObservers.forEach(NotificationCenter.default.removeObserver(_:))
    }
}

extension NSTextView {
    func viewRect(forCharacterRange range: NSRange, using bridge: LayoutBridge?) -> CGRect? {
        guard range.location != NSNotFound,
              let bridge = bridge,
              let textContainer = textContainer else { return nil }
        var boundingRect = bridge.boundingRect(forCharacterRange: range, in: textContainer)
        let containerOrigin = textContainerOrigin
        boundingRect.origin.x += containerOrigin.x
        boundingRect.origin.y += containerOrigin.y
        // The text view sits inside a container document view, offset by the header
        // band (y) and the reading-column centering (x), so its glyph rects
        // (text-view-local) must be lifted into the document view's space before
        // subtracting the scroll offset (which is in document-view space).
        // `convert(.zero, to: doc)` covers both offsets and self-zeroes if this text
        // view ever IS the document view.
        if let scrollView = enclosingScrollView {
            if let doc = scrollView.documentView, doc !== self {
                let originInDoc = convert(CGPoint.zero, to: doc)
                boundingRect.origin.x += originInDoc.x
                boundingRect.origin.y += originInDoc.y
            }
            let contentOffset = scrollView.contentView.bounds.origin
            boundingRect.origin.x -= contentOffset.x
            boundingRect.origin.y -= contentOffset.y
        }
        return boundingRect
    }
}

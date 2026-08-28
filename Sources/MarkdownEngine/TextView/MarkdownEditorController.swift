//
//  MarkdownEditorController.swift
//  MarkdownEngine
//

// The embedder-facing handle on a live editor: apply text patches from
// outside SwiftUI's binding, and reach the underlying `NSTextView` for the
// system affordances the engine deliberately does not wrap (`NSTextFinder`,
// a modal key layer, typewriter scrolling).

import AppKit

/// One replacement in UTF-16 display coordinates, the same currency
/// ``MarkdownTextMutation`` reports edits in.
public struct MarkdownTextPatch: Sendable, Equatable {
    /// Range in the document *before* this patch is applied.
    public let range: NSRange
    /// Text that replaces `range`. Empty string deletes.
    public let replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// Handle on one live ``NativeTextViewWrapper``.
///
/// Construct one, hold it (`@State` / a store), and pass it to the wrapper.
/// The engine attaches on `makeNSView` and detaches on teardown; every member
/// is inert while ``isAttached`` is `false`.
///
/// ### Applying an external edit
///
/// A remote edit, an undo-tree navigation or a canonicalisation must NOT be
/// pushed through the `text` binding: a binding change the engine did not
/// originate rebuilds the whole text storage, which resets the selection to
/// `{0, 0}` and strands the scroll offset. Call ``applyPatch(range:replacement:actionName:registersUndo:)``
/// instead. It runs the same
/// `shouldChangeText → replaceCharacters → didChangeText` sequence a keystroke
/// takes, so only the touched paragraphs restyle, the caret is transformed
/// through the edit rather than reset, and the change is reported back through
/// `onTextMutation` like any other.
///
/// ### Owning undo
///
/// Set ``MarkdownEditorConfiguration/undo`` to ``UndoPolicy/external`` and the
/// engine stops registering AppKit undo actions (`allowsUndo = false`); ⌘Z then
/// reaches whatever the embedder puts in the responder chain. Supply
/// ``undoManager`` if the embedder wants the text view to see a specific one.
@MainActor
public final class MarkdownEditorController {
    /// The document's backing store, shared by every view showing it.
    ///
    /// TextKit 2 keeps the text in an `NSTextContentStorage` and lets any
    /// number of `NSTextLayoutManager`s lay it out. Owning it here — at
    /// document scope, on the object the embedder holds for the lifetime of the
    /// document — is what makes showing one document in two windows cheap and
    /// coherent: both views read the same characters and the same attributes,
    /// so an edit through either is immediately the other's edit too.
    ///
    /// A wrapper given a controller builds its text view on this storage. One
    /// given no controller keeps `NSTextView`'s own auto-created stack.
    public let textContentStorage = NSTextContentStorage()

    /// The text view backing the attached editor, or `nil` before attach /
    /// after teardown.
    ///
    /// Exposed for the system affordances the engine does not wrap:
    /// `NSTextFinder` (set it as the finder's client and
    /// `NSTextFinderBarContainer` host), a `keyDown` interception layer,
    /// typewriter scrolling driven off `textLayoutManager`. Treat it as
    /// read-mostly: mutate the *text* through ``applyPatch(range:replacement:actionName:registersUndo:)``,
    /// never by assigning `string` (that is the full-rebuild path this API exists
    /// to avoid).
    public var textView: NSTextView? { attachments.last?.textView }

    /// Every view currently showing this document, oldest first.
    ///
    /// One document can be open in several windows, and each has its own text
    /// view, layout manager, selection and scroll position. Keeping only the
    /// most recent one meant closing either window cleared the controller for
    /// the other, which then answered `nil` to everything.
    public var textViews: [NSTextView] { attachments.compactMap(\.textView) }

    private struct Attachment {
        weak var textView: NSTextView?
        weak var coordinator: NativeTextViewCoordinator?
    }

    private var attachments: [Attachment] = []

    /// Undo manager handed to the text view when
    /// ``MarkdownEditorConfiguration/undo`` is ``UndoPolicy/external``.
    /// Ignored under ``UndoPolicy/engine``.
    public weak var undoManager: UndoManager?

    /// Fires once the controller is attached to (or detached from) a live
    /// editor, so an embedder can install a finder / key layer at the right
    /// moment instead of polling ``isAttached``.
    public var onAttach: ((NSTextView?) -> Void)?

    private var coordinator: NativeTextViewCoordinator? { attachments.last?.coordinator }

    /// The presentation every attached view must agree on.
    ///
    /// Marker hiding is a FONT SIZE and a kern — it changes layout, not just
    /// colour — so it cannot live in a per-layout-manager rendering-attributes
    /// overlay the way a highlight could. Presentation-dependent styling
    /// therefore has to be written into the shared storage, and two views that
    /// disagree about it overwrite each other: a raw rebuild unstyles the rich
    /// view, a rich rebuild shrinks raw's markers to nothing. Until that is
    /// split properly, one controller means one presentation.
    private var presentation: (rawSourceMode: Bool, isEditable: Bool)?

    public init() {}

    /// `true` while at least one live editor is attached.
    public var isAttached: Bool { textView != nil }

    /// The editor's current selection, in UTF-16 display coordinates.
    public var selectedRange: NSRange {
        get { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }
        set { textView?.setSelectedRange(newValue) }
    }

    /// The editor's current text, in display coordinates.
    public var text: String { textView?.string ?? "" }

    // MARK: - Patching

    /// Replace `range` with `replacement` without rebuilding the document.
    ///
    /// - Parameters:
    ///   - range: UTF-16 range in the current text. Out-of-bounds returns `false`.
    ///   - replacement: The new text.
    ///   - actionName: Undo action name, applied only when `registersUndo` is `true`.
    ///   - registersUndo: `false` (the default) brackets the edit in
    ///     `disableUndoRegistration()`/`enableUndoRegistration()`, so someone
    ///     else's edit never becomes a local undo step. Pass `true` only for an
    ///     edit the user themselves initiated through the embedder's UI.
    /// - Returns: `true` when the edit was applied.
    ///
    /// The caret (or selection) is transformed through the edit: text inserted
    /// before it shifts it, text after it leaves it alone, and a selection
    /// overlapping the patch clamps to the patched span. It is never reset to
    /// the top of the document.
    @discardableResult
    public func applyPatch(
        range: NSRange,
        replacement: String,
        actionName: String? = nil,
        registersUndo: Bool = false
    ) -> Bool {
        applyPatches([MarkdownTextPatch(range: range, replacement: replacement)],
                     actionName: actionName,
                     registersUndo: registersUndo)
    }

    /// Apply several patches as one edit.
    ///
    /// Ranges address the document *before any* of them is applied, so a caller
    /// can hand over a diff computed in one pass. The whole batch is validated
    /// first and then applied back to front, so either all of it lands or none
    /// of it does.
    ///
    /// Rules, all of them checked:
    /// - Ranges must be in bounds, and must not split a surrogate pair (see
    ///   ``applyPatch(range:replacement:actionName:registersUndo:)``).
    /// - Ranges must not overlap. A zero-length insertion counts as touching
    ///   the character positions on both sides, so an insertion at the start or
    ///   end of another patch's range is an overlap and is refused: there is no
    ///   defensible order for it, and silently picking one produced `BA` for
    ///   `["A", "B"]` at the same offset.
    /// - Two insertions at the same offset are refused for the same reason.
    ///   Combine them into one patch; only the caller knows which comes first.
    ///
    /// With `registersUndo: true` the whole batch is one undo action.
    @discardableResult
    public func applyPatches(
        _ patches: [MarkdownTextPatch],
        actionName: String? = nil,
        registersUndo: Bool = false
    ) -> Bool {
        guard let textView, let coordinator, !patches.isEmpty else { return false }
        let text = textView.string as NSString
        guard patches.allSatisfy({ isApplicable($0, in: text) }) else { return false }

        // Ascending for the overlap check, descending to apply — a later patch
        // must not shift the range of one that has not been applied yet.
        let ascending = patches.sorted { $0.range.location < $1.range.location }
        for (earlier, later) in zip(ascending, ascending.dropFirst()) {
            // `<` and not `<=`: an insertion exactly where the previous patch
            // ends is ambiguous, not adjacent.
            guard NSMaxRange(earlier.range) < later.range.location
                || (earlier.range.length > 0 && later.range.length > 0
                    && NSMaxRange(earlier.range) <= later.range.location)
            else { return false }
        }

        // One undo group and one coalescing boundary for the batch, not one per
        // patch — the API promises a single edit.
        textView.breakUndoCoalescing()
        let undoManager = textView.undoManager
        if registersUndo { undoManager?.beginUndoGrouping() }
        defer {
            if registersUndo {
                undoManager?.endUndoGrouping()
                if let actionName { undoManager?.setActionName(actionName) }
            }
            textView.breakUndoCoalescing()
        }

        var selection = textView.selectedRange()
        var applied = false
        for patch in ascending.reversed() {
            guard coordinator.applyProgrammaticPatch(
                patch, to: textView, registersUndo: registersUndo) else { continue }
            selection = selection.adjusting(
                forReplacementOf: patch.range,
                withLength: (patch.replacement as NSString).length
            )
            applied = true
        }
        guard applied else { return false }
        textView.setSelectedRange(
            selection.clamped(toLength: (textView.string as NSString).length))
        return true
    }

    /// In bounds, and not cutting a character in half.
    ///
    /// An `NSRange` addresses UTF-16 code units, and an emoji is two of them.
    /// A range that starts or ends between a high and a low surrogate would
    /// build a replacement string containing half a character: the text storage
    /// reassembles the document correctly from the units, but the
    /// ``MarkdownTextMutation`` published to the embedder is not valid UTF-8,
    /// and a sync outbox that JSON-encodes it fails.
    private func isApplicable(_ patch: MarkdownTextPatch, in text: NSString) -> Bool {
        patch.range.location != NSNotFound
            && patch.range.location >= 0
            && patch.range.length >= 0
            && NSMaxRange(patch.range) <= text.length
            && !text.splitsSurrogatePair(at: patch.range.location)
            && !text.splitsSurrogatePair(at: NSMaxRange(patch.range))
    }

    /// Bring the editor to `text` by patching the one run that changed.
    ///
    /// The caller has a new whole document — a sync change, a history jump, a
    /// canonicalisation — and wants the editor to hold it without losing the
    /// caret. A common-prefix/suffix scan is enough: a document edit is one
    /// contiguous change often enough that a real diff would buy nothing, and
    /// an over-wide answer is still correct output, only a bigger restyle.
    ///
    /// - Returns: `true` when the editor now holds `text`.
    @discardableResult
    public func applyText(
        _ text: String,
        actionName: String? = nil,
        registersUndo: Bool = false
    ) -> Bool {
        guard let textView else { return false }
        let old = textView.string
        guard old != text else { return true }
        let patch = MarkdownTextPatch.diff(from: old, to: text)
        return applyPatch(range: patch.range, replacement: patch.replacement,
                          actionName: actionName, registersUndo: registersUndo)
    }

    // MARK: - Attachment (engine-internal)

    /// Whether a view in this presentation may join the document.
    ///
    /// `true` when nothing is attached yet, or when the presentation matches
    /// what is already attached. See ``presentation``.
    public func accepts(rawSourceMode: Bool, isEditable: Bool) -> Bool {
        attachments.removeAll { $0.textView == nil }
        guard !attachments.isEmpty, let presentation else { return true }
        return presentation == (rawSourceMode, isEditable)
    }

    @discardableResult
    func attach(textView: NSTextView, coordinator: NativeTextViewCoordinator) -> Bool {
        attachments.removeAll { $0.textView == nil }
        let incoming = (coordinator.configuration.rawSourceMode, textView.isEditable)
        if let presentation, !attachments.isEmpty, presentation != incoming {
            assertionFailure(
                "A document's views share one text storage, and presentation-dependent "
                + "styling is written into it, so two presentations overwrite each other. "
                + "This controller is showing raw=\(presentation.rawSourceMode) "
                + "editable=\(presentation.isEditable); a view asked to join as "
                + "raw=\(incoming.0) editable=\(incoming.1). Give each presentation its "
                + "own MarkdownEditorController.")
            return false
        }
        self.presentation = incoming
        if attachments.contains(where: { $0.textView === textView && $0.coordinator === coordinator }) {
            return true
        }
        attachments.removeAll { $0.textView === textView }
        attachments.append(Attachment(textView: textView, coordinator: coordinator))
        onAttach?(textView)
        return true
    }

    /// Detach one view. The others keep working — closing one window must not
    /// silence the document in the window still open.
    func detach(textView: NSTextView) {
        let hadView = attachments.contains { $0.textView === textView }
        // Break the storage association too, or the content storage keeps the
        // layout manager (and through it the view) alive and keeps laying out
        // for a window nobody can see.
        if let layoutManager = textView.textLayoutManager,
           layoutManager.textContentManager === textContentStorage {
            textContentStorage.removeTextLayoutManager(layoutManager)
        }
        attachments.removeAll { $0.textView === textView || $0.textView == nil }
        if attachments.isEmpty { presentation = nil }
        guard hadView else { return }
        onAttach?(self.textView)
    }

    /// Move a layout manager onto this document's storage, off whatever it was
    /// on before.
    ///
    /// The embedder can hand a view a different controller between updates —
    /// switching which document a window shows. Re-pointing the attachment is
    /// not enough: the view lays out through its layout manager, and that is
    /// still bound to the previous document's storage, so the window keeps
    /// showing the old document and any edit lands in it.
    func adopt(layoutManager: NSTextLayoutManager) {
        guard layoutManager.textContentManager !== textContentStorage else { return }
        (layoutManager.textContentManager as? NSTextContentStorage)?
            .removeTextLayoutManager(layoutManager)
        textContentStorage.addTextLayoutManager(layoutManager)
    }

    /// Tell every other attached view that the document changed underneath it.
    ///
    /// Each coordinator memoises its own parse keyed on a counter it bumps
    /// itself, so an edit made through one view left the others' caches looking
    /// valid. A same-length edit does not even change the length they check
    /// against, so the stale parse was used verbatim and the other window
    /// styled syntax that is no longer there.
    func documentDidChange(from coordinator: NativeTextViewCoordinator?) {
        for attachment in attachments where attachment.coordinator !== coordinator {
            attachment.coordinator?.invalidateParseCache()
        }
    }
}

// MARK: - Range transformation

extension NSRange {
    /// This range as it stands after `edited` was replaced by `newLength`
    /// characters. A location before the edit is untouched, one after it
    /// shifts, and one inside the replaced span clamps into the replacement.
    func adjusting(forReplacementOf edited: NSRange, withLength newLength: Int) -> NSRange {
        let delta = newLength - edited.length
        func map(_ location: Int) -> Int {
            if location <= edited.location { return location }
            if location >= NSMaxRange(edited) { return location + delta }
            return edited.location + Swift.min(location - edited.location, newLength)
        }
        let start = map(location)
        return NSRange(location: start, length: Swift.max(0, map(NSMaxRange(self)) - start))
    }

    func clamped(toLength length: Int) -> NSRange {
        let start = Swift.min(Swift.max(0, location), length)
        return NSRange(location: start, length: Swift.min(Swift.max(0, self.length), length - start))
    }
}

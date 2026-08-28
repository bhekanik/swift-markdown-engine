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
    public private(set) weak var textView: NSTextView?

    /// Undo manager handed to the text view when
    /// ``MarkdownEditorConfiguration/undo`` is ``UndoPolicy/external``.
    /// Ignored under ``UndoPolicy/engine``.
    public weak var undoManager: UndoManager?

    /// Fires once the controller is attached to (or detached from) a live
    /// editor, so an embedder can install a finder / key layer at the right
    /// moment instead of polling ``isAttached``.
    public var onAttach: ((NSTextView?) -> Void)?

    private weak var coordinator: NativeTextViewCoordinator?

    public init() {}

    /// `true` while a live editor is attached.
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
    /// can hand over a diff computed in one pass. They must not overlap; they
    /// are applied back to front so earlier ranges stay valid.
    @discardableResult
    public func applyPatches(
        _ patches: [MarkdownTextPatch],
        actionName: String? = nil,
        registersUndo: Bool = false
    ) -> Bool {
        guard let textView, let coordinator, !patches.isEmpty else { return false }
        let length = (textView.string as NSString).length
        let ordered = patches.sorted { $0.range.location > $1.range.location }
        guard ordered.allSatisfy({ $0.range.location != NSNotFound && $0.range.location >= 0
            && $0.range.length >= 0 && NSMaxRange($0.range) <= length }) else { return false }
        // Overlap would make the "ranges are all pre-edit" contract unsatisfiable.
        for (a, b) in zip(ordered, ordered.dropFirst())
        where b.range.location + b.range.length > a.range.location { return false }

        var selection = textView.selectedRange()
        var applied = false
        for patch in ordered {
            guard apply(patch, to: textView, coordinator: coordinator,
                        actionName: actionName, registersUndo: registersUndo) else { continue }
            selection = selection.adjusting(
                forReplacementOf: patch.range,
                withLength: (patch.replacement as NSString).length
            )
            applied = true
        }
        guard applied else { return false }
        let newLength = (textView.string as NSString).length
        textView.setSelectedRange(selection.clamped(toLength: newLength))
        return true
    }

    private func apply(
        _ patch: MarkdownTextPatch,
        to textView: NSTextView,
        coordinator: NativeTextViewCoordinator,
        actionName: String?,
        registersUndo: Bool
    ) -> Bool {
        coordinator.applyProgrammaticPatch(
            patch, to: textView, actionName: actionName, registersUndo: registersUndo)
    }

    // MARK: - Attachment (engine-internal)

    func attach(textView: NSTextView, coordinator: NativeTextViewCoordinator) {
        guard self.textView !== textView || self.coordinator !== coordinator else { return }
        self.textView = textView
        self.coordinator = coordinator
        onAttach?(textView)
    }

    func detach() {
        guard textView != nil else { return }
        textView = nil
        coordinator = nil
        onAttach?(nil)
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

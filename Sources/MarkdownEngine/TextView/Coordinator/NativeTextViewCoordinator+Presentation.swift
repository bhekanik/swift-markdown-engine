//
//  NativeTextViewCoordinator+Presentation.swift
//  MarkdownEngine
//
//  Switching the lens on one view: rich (markers hidden, styled), raw (source,
//  monospace, AppKit's input rewrites off) and back.
//

import AppKit

extension NativeTextViewCoordinator {
    /// Run the complete rich ⇄ raw transition.
    ///
    /// One method rather than a sequence the caller assembles, because the
    /// halves are not independent and a partial run is silently wrong: flipping
    /// `rawSourceMode` and rebuilding without `enterRawSourceMode` leaves the
    /// markers monospaced but AppKit still substituting quotes, replacing text
    /// and smart-inserting spaces INTO MARKDOWN SOURCE, which is the one thing
    /// raw mode exists to prevent.
    ///
    /// What a transition is, in full:
    ///
    /// - the five input rewrites off (entering) or restored from the snapshot
    ///   taken on the way in (leaving);
    /// - `rawSourceMode` synced onto both the coordinator's configuration and
    ///   the text view's, which the keystroke handlers read live;
    /// - undo coalescing closed and the document's undo stack cleared — the
    ///   recorded ranges describe text laid out under the other presentation;
    /// - a full rebuild, because marker hiding is a font size and a kern, so
    ///   every styled range in the document changes;
    /// - on the way out of raw, the caret-position-dependent autocorrect
    ///   settings recomputed against the rebuilt document and the snapshot
    ///   dropped.
    ///
    /// Editability is the other presentation axis (it is what separates preview
    /// from rich) and is set unconditionally by the caller on every update
    /// pass, since changing it alone needs none of the above.
    ///
    /// - Parameters:
    ///   - rawSourceMode: The presentation to move to.
    ///   - textView: The attached view.
    ///   - documentId: Key for the per-document undo stack to clear.
    ///   - text: The document, which the rebuild lays out afresh.
    func applyPresentationChange(
        to rawSourceMode: Bool,
        in textView: NSTextView,
        documentId: String,
        text: String
    ) {
        notifyTextFinderClientStringWillChange(in: textView)
        if rawSourceMode {
            enterRawSourceMode(textView)
        } else {
            restoreRawSourceInputSettings(textView)
        }
        configuration.rawSourceMode = rawSourceMode
        (textView as? NativeTextView)?.configuration.rawSourceMode = rawSourceMode
        textView.breakUndoCoalescing()
        undoManagers[documentId]?.removeAllActions()

        rebuildTextStorageAndStyle(
            textView,
            from: text,
            invalidateLayout: true,
            notifyTextFinder: false
        )

        if !rawSourceMode {
            finishLeavingRawSourceMode(textView)
        }
    }
}

extension NativeTextViewCoordinator {
    /// Report an edit to the embedder — unless this view speaks for nobody.
    ///
    /// A detached view's keystrokes are not edits to the document it was
    /// refused. Publishing them would put text the document does not contain
    /// into the undo tree and the sync outbox.
    func publish(_ mutation: MarkdownTextMutation) {
        guard !isDetachedFromDocument else { return }
        onTextMutation?(mutation)
    }

    /// Write the editor's text back to the embedder's binding — same rule, and
    /// the more damaging half: the binding IS the embedder's document, so a
    /// detached view writing to it replaces the real text with its own.
    func writeBindingBack(_ newText: String) {
        guard !isDetachedFromDocument else { return }
        text = newText
    }

    /// Take a controller that has just released its view.
    ///
    /// This view was built while another still held the controller, so it has a
    /// TextKit stack of its own and reaches nothing. See
    /// ``MarkdownEditorController/awaitSlot(_:)`` for why the handover is pushed
    /// here rather than retried on a later update pass — for a remount, there is
    /// no later update pass.
    ///
    /// The DOCUMENT's storage is authoritative, never this view's snapshot: the
    /// text this view was built from can be older than what the outgoing view
    /// left behind, and writing it back would revert edits the embedder has
    /// already been told about.
    func takeOverFreedController(_ controller: MarkdownEditorController) {
        guard let textView, editorController == nil else { return }
        // `onAttach` can install Finder and read its client immediately. Reserve
        // the slot now, but announce it only after this view uses the document's
        // authoritative storage instead of its stale SwiftUI snapshot.
        guard controller.attach(
            textView: textView,
            coordinator: self,
            notifyEmbedder: false
        ) else { return }
        editorController = controller
        pendingAttachmentAnnouncement = controller
        hasPendingAttachmentAnnouncement = true
        isDetachedFromDocument = false

        // Zeroed on both sides of the move, as in a controller swap: detaching
        // the layout manager leaves the view with no content manager, and the
        // selection it reads back afterwards is neither zero nor in range.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if let layoutManager = textView.textLayoutManager {
            controller.adopt(layoutManager: layoutManager)
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let authoritative = textView.string
        lastSyncedText = authoritative
        previousDisplayLength = (authoritative as NSString).length
        invalidateParseCache()
        rebuildTextStorageAndStyle(textView, from: authoritative, invalidateLayout: true)
        didInitialFormatting = true
        reportPendingAttachment(textView)
    }
}

//
//  SingleViewTests.swift
//  MarkdownEngineTests
//
//  One attached view per controller.
//
//  Marker hiding is a font size and a kern, so presentation-dependent styling
//  has to be written into the content storage itself. Two views over one
//  storage therefore overwrite each other's attributes, and no arrangement of
//  rendering attributes can fix it — TextKit 2 rendering attributes cannot
//  collapse a marker's advance. So a controller drives exactly one view, and
//  two windows on one document are two controllers kept in step by forwarding
//  the edit descriptors between them (`twoControllersStayInSync` below is that
//  model in miniature).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("One view per controller", .serialized)
struct SingleViewTests {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private final class MutableTextBox {
        var value: String
        private(set) var bindingWriteCount = 0

        init(_ value: String) {
            self.value = value
        }

        func apply(_ mutation: MarkdownTextMutation) {
            value = (value as NSString).replacingCharacters(
                in: mutation.range,
                with: mutation.replacement
            )
        }

        func writeFromBinding(_ value: String) {
            bindingWriteCount += 1
            self.value = value
        }
    }

    private final class MutationBox {
        var values: [MarkdownTextMutation] = []
    }


    private final class TextFinderResponder: MarkdownTextFinderActionResponder {
        var performed: [NSTextFinder.Action] = []
        var validated: [NSTextFinder.Action] = []
        var stringWillChangeCount = 0
        var validationResult = false
        var onStringWillChange: (() -> Void)?

        func performTextFinderAction(_ action: NSTextFinder.Action) {
            performed.append(action)
        }

        func validateTextFinderAction(_ action: NSTextFinder.Action) -> Bool {
            validated.append(action)
            return validationResult
        }

        func textFinderClientStringWillChange() {
            stringWillChangeCount += 1
            onStringWillChange?()
        }
    }

    /// A view on `controller`'s storage, driven by a coordinator, without
    /// SwiftUI — the AppKit entry point.
    private func view(on controller: MarkdownEditorController,
                      text: String) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600,
                                                     height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        controller.textContentStorage.addTextLayoutManager(layoutManager)
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400),
                                      textContainer: container)
        textView.isEditable = true
        let coordinator = NativeTextViewWrapper(text: .constant(text), controller: controller,
                                                fontName: "Helvetica", fontSize: 16)
            .makeCoordinator()
        coordinator.adopt(textView, text: text)
        return (textView, coordinator)
    }

    private func textViews(in view: NSView) -> [NativeTextView] {
        let here = (view as? NativeTextView).map { [$0] } ?? []
        return here + view.subviews.flatMap(textViews)
    }

    // MARK: - The contract

    @Test("a second view is refused")
    func secondAttachIsRefused() {
        let controller = MarkdownEditorController()
        let (first, _) = view(on: controller, text: "alpha\n")
        let second = NativeTextView(frame: .zero)
        let coordinator = NativeTextViewWrapper(text: .constant("alpha\n"), controller: controller,
                                                fontName: "Helvetica", fontSize: 16)
            .makeCoordinator()

        #expect(controller.attach(textView: second, coordinator: coordinator) == false)
        #expect(controller.textView === first, "the second view took the document")
    }

    @Test("re-attaching the same view is not a second attach")
    func reattachingTheSameViewIsFine() {
        let controller = MarkdownEditorController()
        let (only, coordinator) = view(on: controller, text: "alpha\n")

        #expect(controller.attach(textView: only, coordinator: coordinator))
        #expect(controller.textView === only)
    }

    @Test("detaching frees the slot")
    func detachFreesTheSlot() {
        let controller = MarkdownEditorController()
        let (first, _) = view(on: controller, text: "alpha\n")
        controller.detach(textView: first)
        #expect(controller.isAttached == false)

        let (second, _) = view(on: controller, text: "alpha\n")
        #expect(controller.textView === second)
    }

    @Test("detaching drops the layout manager off the storage")
    func detachReleasesTheLayoutManager() {
        let controller = MarkdownEditorController()
        let (only, _) = view(on: controller, text: "alpha\n")
        #expect(controller.textContentStorage.textLayoutManagers.count == 1)

        controller.detach(textView: only)

        #expect(controller.textContentStorage.textLayoutManagers.isEmpty,
                "the closed window's layout manager is still laying the document out")
        #expect(only.textLayoutManager?.textContentManager == nil)
    }

    @Test("detaching a view that was never attached changes nothing")
    func detachingAStrangerIsANoOp() {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let (only, _) = view(on: controller, text: "alpha\n")
        controller.detach(textView: NSTextView(frame: .zero))
        #expect(controller.textView === only)
    }

    @Test("the last view going leaves the controller inert")
    func detachingLeavesTheControllerInert() {
        let controller = MarkdownEditorController()
        let (only, _) = view(on: controller, text: "alpha\n")
        controller.detach(textView: only)

        #expect(controller.isAttached == false)
        #expect(controller.applyPatch(range: NSRange(location: 0, length: 1),
                                      replacement: "b") == false)
    }

    @Test("the embedder owns Find actions and pre-edit invalidation")
    func findActionsReachTheEmbedder() {
        let controller = MarkdownEditorController()
        let responder = TextFinderResponder()
        controller.textFinderActionResponder = responder
        let (textView, _) = view(on: controller, text: "alpha\n")
        let item = NSMenuItem(
            title: "Find",
            action: #selector(NSTextView.performTextFinderAction(_:)),
            keyEquivalent: ""
        )
        item.tag = NSTextFinder.Action.showFindInterface.rawValue

        textView.performTextFinderAction(item)

        #expect(responder.performed == [.showFindInterface])
        #expect(textView.validateUserInterfaceItem(item) == false)
        #expect(responder.validated == [.showFindInterface])

        textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(responder.stringWillChangeCount == 1)
    }

    @Test("a Binding splice stays programmatic across a nested Finder patch")
    func bindingSpliceSurvivesReentrantFinderPatch() async {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let text = MutableTextBox("- item")
        var mutations: [MarkdownTextMutation] = []
        let wrapper = NativeTextViewWrapper(
            text: Binding(
                get: { text.value },
                set: { text.writeFromBinding($0) }
            ),
            controller: controller,
            fontName: "Helvetica",
            fontSize: 16,
            onTextMutation: { mutation in
                mutations.append(mutation)
                text.apply(mutation)
            }
        )
        let coordinator = wrapper.makeCoordinator()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: 400))
        layoutManager.textContainer = container
        controller.textContentStorage.addTextLayoutManager(layoutManager)
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            textContainer: container
        )
        textView.isEditable = true
        coordinator.adopt(textView, text: text.value)

        let responder = TextFinderResponder()
        var didApplyNestedPatch = false
        responder.onStringWillChange = {
            guard !didApplyNestedPatch else { return }
            didApplyNestedPatch = true
            #expect(controller.applyPatch(
                range: NSRange(location: 2, length: 1),
                replacement: "I"
            ))
        }
        controller.textFinderActionResponder = responder

        text.value = "- item\n"
        let outerResult = coordinator.spliceExternalText(
            text.value,
            in: textView,
            publishesMutation: false
        )
        await drainMainQueue()

        #expect(outerResult == .applied)
        #expect(textView.string == "- Item\n")
        #expect(text.value == "- Item\n")
        #expect(coordinator.lastSyncedText == "- Item\n")
        #expect(mutations == [MarkdownTextMutation(
            range: NSRange(location: 2, length: 1),
            replacement: "I"
        )])
        #expect(text.bindingWriteCount == 0)
        #expect(controller.documentRevision == 2)
        #expect(controller.documentMutationDelta == 1)
        #expect(controller.documentPublishedDelta == 0)

        didApplyNestedPatch = false
        responder.onStringWillChange = {
            guard !didApplyNestedPatch else { return }
            didApplyNestedPatch = true
            #expect(controller.applyPatch(
                range: NSRange(location: 0, length: 0),
                replacement: "# "
            ))
        }
        text.value = "- Item\n!"
        let shiftedOuterResult = coordinator.spliceExternalText(
            text.value,
            in: textView,
            publishesMutation: false
        )
        await drainMainQueue()

        #expect(shiftedOuterResult == .applied)
        #expect(textView.string == "# - Item\n!")
        #expect(text.value == "# - Item\n!")
        #expect(coordinator.lastSyncedText == "# - Item\n!")
        #expect(mutations == [
            MarkdownTextMutation(
                range: NSRange(location: 2, length: 1),
                replacement: "I"
            ),
            MarkdownTextMutation(
                range: NSRange(location: 0, length: 0),
                replacement: "# "
            )
        ])
        #expect(text.bindingWriteCount == 0)
        #expect(controller.documentRevision == 4)
        #expect(controller.documentMutationDelta == 4)
        #expect(controller.documentPublishedDelta == 2)
    }

    @Test("an overlapping Finder patch keeps the nested edit authoritative")
    func bindingSpliceDoesNotOverwriteOverlappingFinderPatch() throws {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let text = MutableTextBox("abc")
        var mutations: [MarkdownTextMutation] = []
        func root() -> MutableAttachmentHost {
            MutableAttachmentHost(
                text: text,
                controller: controller,
                onMutation: { mutation in
                    mutations.append(mutation)
                    text.apply(mutation)
                },
                onAttachmentChange: { _ in }
            )
        }
        let host = NSHostingView(rootView: root())
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let textView = try #require(controller.textView)
        let responder = TextFinderResponder()
        var didApplyNestedPatch = false
        responder.onStringWillChange = {
            guard !didApplyNestedPatch else { return }
            didApplyNestedPatch = true
            #expect(controller.applyPatch(
                range: NSRange(location: 1, length: 1),
                replacement: "B"
            ))
        }
        controller.textFinderActionResponder = responder

        text.value = "axc"
        host.rootView = root()
        host.layoutSubtreeIfNeeded()

        #expect(textView.string == "aBc")
        #expect(text.value == "aBc")
        #expect(mutations == [MarkdownTextMutation(
            range: NSRange(location: 1, length: 1),
            replacement: "B"
        )])
        #expect(text.bindingWriteCount == 0)
        #expect(controller.documentRevision == 1)
        #expect(controller.documentMutationDelta == 0)
        #expect(controller.documentPublishedDelta == 0)

        host.rootView = root()
        host.layoutSubtreeIfNeeded()
        #expect(textView.string == text.value)
        #expect(mutations.count == 1)
    }

    @Test("Finder edits touching a Binding patch boundary defer reconciliation")
    func bindingSpliceDefersBoundaryConflicts() async {
        func runCase(
            nestedPatch: MarkdownTextPatch,
            bindingAfterNestedPatch: String,
            liveAfterNestedPatch: String,
            expectedDelta: Int,
            expectedSelectionAfterNestedPatch: Int,
            expectedFinalRevision: UInt64
        ) async {
            let controller = MarkdownEditorController()
            let text = MutableTextBox("abc")
            var mutations: [MarkdownTextMutation] = []
            let wrapper = NativeTextViewWrapper(
                text: Binding(
                    get: { text.value },
                    set: { text.writeFromBinding($0) }
                ),
                controller: controller,
                fontName: "Helvetica",
                fontSize: 16,
                onTextMutation: { mutation in
                    mutations.append(mutation)
                    text.apply(mutation)
                }
            )
            let coordinator = wrapper.makeCoordinator()
            let layoutManager = NSTextLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 600, height: 400))
            layoutManager.textContainer = container
            controller.textContentStorage.addTextLayoutManager(layoutManager)
            let textView = NativeTextView(
                frame: NSRect(x: 0, y: 0, width: 600, height: 400),
                textContainer: container
            )
            textView.isEditable = true
            coordinator.adopt(textView, text: text.value)
            textView.setSelectedRange(NSRange(location: 3, length: 0))

            let responder = TextFinderResponder()
            var didApplyNestedPatch = false
            responder.onStringWillChange = {
                guard !didApplyNestedPatch else { return }
                didApplyNestedPatch = true
                #expect(controller.applyPatch(
                    range: nestedPatch.range,
                    replacement: nestedPatch.replacement
                ))
            }
            controller.textFinderActionResponder = responder

            text.value = "axc"
            let firstResult = coordinator.spliceExternalText(
                text.value,
                in: textView,
                publishesMutation: false
            )

            #expect(firstResult == .invalidated)
            #expect(textView.string == liveAfterNestedPatch)
            #expect(text.value == bindingAfterNestedPatch)
            #expect(coordinator.lastSyncedText == liveAfterNestedPatch)
            #expect(mutations == [MarkdownTextMutation(
                range: nestedPatch.range,
                replacement: nestedPatch.replacement
            )])
            #expect(text.bindingWriteCount == 0)
            #expect(controller.documentRevision == 1)
            #expect(controller.documentMutationDelta == expectedDelta)
            #expect(controller.documentPublishedDelta == expectedDelta)
            #expect(textView.selectedRange() == NSRange(
                location: expectedSelectionAfterNestedPatch,
                length: 0
            ))
            #expect(coordinator.pendingTextMutation == nil)
            #expect(coordinator.pendingTextMutationStartLength == nil)
            #expect(coordinator.pendingEditedRange == nil)
            #expect(coordinator.pendingEditCount == 0)
            #expect(coordinator.pendingBacktickWindow == nil)
            #expect(!coordinator.pendingExtFenceTouched)
            #expect(!coordinator.pendingListStructureEdit)
            #expect(coordinator.pendingPreEditActiveTokenIndices == nil)

            let secondResult = coordinator.spliceExternalText(
                text.value,
                in: textView,
                publishesMutation: false
            )

            #expect(secondResult == .applied)
            #expect(textView.string == text.value)
            #expect(coordinator.lastSyncedText == text.value)
            #expect(mutations.count == 1)
            #expect(text.bindingWriteCount == 0)
            #expect(controller.documentRevision == expectedFinalRevision)
            #expect(controller.documentMutationDelta == expectedDelta)
            #expect(controller.documentPublishedDelta == expectedDelta)
            #expect(textView.selectedRange() == NSRange(
                location: expectedSelectionAfterNestedPatch,
                length: 0
            ))

            await drainMainQueue()
            #expect(textView.string == text.value)
            #expect(coordinator.lastSyncedText == text.value)
            #expect(text.bindingWriteCount == 0)
        }

        _ = NSApplication.shared
        await runCase(
            nestedPatch: MarkdownTextPatch(
                range: NSRange(location: 1, length: 1),
                replacement: "B"
            ),
            bindingAfterNestedPatch: "aBc",
            liveAfterNestedPatch: "aBc",
            expectedDelta: 0,
            expectedSelectionAfterNestedPatch: 3,
            expectedFinalRevision: 1
        )
        await runCase(
            nestedPatch: MarkdownTextPatch(
                range: NSRange(location: 1, length: 0),
                replacement: "Y"
            ),
            bindingAfterNestedPatch: "aYxc",
            liveAfterNestedPatch: "aYbc",
            expectedDelta: 1,
            expectedSelectionAfterNestedPatch: 4,
            expectedFinalRevision: 2
        )
        await runCase(
            nestedPatch: MarkdownTextPatch(
                range: NSRange(location: 2, length: 1),
                replacement: ""
            ),
            bindingAfterNestedPatch: "ax",
            liveAfterNestedPatch: "ab",
            expectedDelta: -1,
            expectedSelectionAfterNestedPatch: 2,
            expectedFinalRevision: 2
        )
    }

    @Test("Find replacement refuses ranges invalidated by its pre-change callback")
    func findReplacementRejectsReentrantStaleRanges() {
        func runCase(replaceAll: Bool) {
            let controller = MarkdownEditorController()
            let (textView, coordinator) = view(on: controller, text: "alpha alpha")
            var mutations: [MarkdownTextMutation] = []
            coordinator.onTextMutation = { mutations.append($0) }
            let responder = TextFinderResponder()
            var didApplyNestedPatch = false
            responder.onStringWillChange = {
                guard !didApplyNestedPatch else { return }
                didApplyNestedPatch = true
                #expect(controller.applyPatch(
                    range: NSRange(location: 0, length: 6),
                    replacement: ""
                ))
            }
            controller.textFinderActionResponder = responder

            if replaceAll {
                coordinator.handleReplaceAll(query: "alpha", replacement: "X")
            } else {
                coordinator.handleReplaceCurrent(
                    query: "alpha",
                    replacement: "X",
                    currentIndex: 1
                )
            }

            #expect(textView.string == "alpha")
            #expect(mutations == [MarkdownTextMutation(
                range: NSRange(location: 0, length: 6),
                replacement: ""
            )])
            #expect(controller.documentRevision == 1)
            #expect(coordinator.pendingTextMutation == nil)
            #expect(coordinator.pendingTextMutationStartLength == nil)
            #expect(coordinator.pendingEditedRange == nil)
            #expect(coordinator.pendingEditCount == 0)
        }

        runCase(replaceAll: false)
        runCase(replaceAll: true)

        let wrapper = NativeTextViewWrapper(
            text: .constant("alpha alpha"),
            fontName: "Helvetica",
            fontSize: 16
        )
        let coordinator = wrapper.makeCoordinator()
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400)
        )
        textView.isEditable = true
        coordinator.adopt(textView, text: "alpha alpha")

        coordinator.handleReplaceAll(query: "alpha", replacement: "X")

        #expect(textView.string == "X X")
    }

    @Test("rebuild defers stale input after a Finder callback edits storage")
    func rebuildDoesNotOverwriteReentrantFinderPatch() async {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let text = MutableTextBox("alpha")
        var mutations: [MarkdownTextMutation] = []
        let wrapper = NativeTextViewWrapper(
            text: Binding(
                get: { text.value },
                set: { text.writeFromBinding($0) }
            ),
            controller: controller,
            fontName: "Helvetica",
            fontSize: 16,
            onTextMutation: { mutation in
                mutations.append(mutation)
                text.apply(mutation)
            }
        )
        let coordinator = wrapper.makeCoordinator()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: 400))
        layoutManager.textContainer = container
        controller.textContentStorage.addTextLayoutManager(layoutManager)
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            textContainer: container
        )
        textView.isEditable = true
        coordinator.adopt(textView, text: text.value)

        let responder = TextFinderResponder()
        var didApplyNestedPatch = false
        responder.onStringWillChange = {
            guard !didApplyNestedPatch else { return }
            didApplyNestedPatch = true
            #expect(controller.applyPatch(
                range: NSRange(location: 0, length: 1),
                replacement: "A"
            ))
        }
        controller.textFinderActionResponder = responder

        text.value = "omega"
        coordinator.rebuildTextStorageAndStyle(textView, from: text.value)
        await drainMainQueue()

        #expect(textView.string == "Alpha")
        #expect(text.value == "Amega")
        #expect(coordinator.lastSyncedText == "Alpha")
        #expect(text.bindingWriteCount == 0)
        #expect(mutations == [MarkdownTextMutation(
            range: NSRange(location: 0, length: 1),
            replacement: "A"
        )])
        #expect(controller.documentRevision == 1)

        coordinator.rebuildTextStorageAndStyle(textView, from: text.value)
        #expect(textView.string == "Amega")
        #expect(coordinator.lastSyncedText == "Amega")
        #expect(mutations.count == 1)
        #expect(text.bindingWriteCount == 0)
    }

    @Test("presentation flips keep edits made by the Finder callback")
    func presentationChangeDoesNotOverwriteReentrantFinderPatch() async {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let text = MutableTextBox("alpha")
        var mutations: [MarkdownTextMutation] = []
        let wrapper = NativeTextViewWrapper(
            text: Binding(
                get: { text.value },
                set: { text.writeFromBinding($0) }
            ),
            controller: controller,
            fontName: "Helvetica",
            fontSize: 16,
            onTextMutation: { mutation in
                mutations.append(mutation)
                text.apply(mutation)
            }
        )
        let coordinator = wrapper.makeCoordinator()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: 400))
        layoutManager.textContainer = container
        controller.textContentStorage.addTextLayoutManager(layoutManager)
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            textContainer: container
        )
        textView.isEditable = true
        coordinator.adopt(textView, text: text.value)

        let responder = TextFinderResponder()
        var nestedPatch = MarkdownTextPatch(
            range: NSRange(location: 0, length: 1),
            replacement: "A"
        )
        var didApplyNestedPatch = false
        responder.onStringWillChange = {
            guard !didApplyNestedPatch else { return }
            didApplyNestedPatch = true
            #expect(controller.applyPatch(
                range: nestedPatch.range,
                replacement: nestedPatch.replacement
            ))
        }
        controller.textFinderActionResponder = responder

        let enteringSnapshot = text.value
        coordinator.applyPresentationChange(
            to: true,
            in: textView,
            documentId: "doc",
            text: enteringSnapshot
        )
        await drainMainQueue()
        #expect(textView.string == "Alpha")
        #expect(text.value == "Alpha")
        #expect(coordinator.lastSyncedText == "Alpha")

        nestedPatch = MarkdownTextPatch(
            range: NSRange(location: 2, length: 1),
            replacement: "P"
        )
        didApplyNestedPatch = false
        let leavingSnapshot = text.value
        coordinator.applyPresentationChange(
            to: false,
            in: textView,
            documentId: "doc",
            text: leavingSnapshot
        )
        await drainMainQueue()

        #expect(textView.string == "AlPha")
        #expect(text.value == "AlPha")
        #expect(coordinator.lastSyncedText == "AlPha")
        #expect(text.bindingWriteCount == 0)
        #expect(mutations == [
            MarkdownTextMutation(
                range: NSRange(location: 0, length: 1),
                replacement: "A"
            ),
            MarkdownTextMutation(
                range: NSRange(location: 2, length: 1),
                replacement: "P"
            )
        ])
        #expect(controller.documentRevision == 2)
    }

    @Test("the latest rich and raw edits write the Binding once")
    func typingWritebackUsesLatestLiveText() async {
        func runCase(rawSourceMode: Bool) async {
            let controller = MarkdownEditorController()
            let text = MutableTextBox("alpha")
            var configuration = MarkdownEditorConfiguration.default
            configuration.rawSourceMode = rawSourceMode
            let wrapper = NativeTextViewWrapper(
                text: Binding(
                    get: { text.value },
                    set: { text.writeFromBinding($0) }
                ),
                configuration: configuration,
                controller: controller,
                fontName: "Helvetica",
                fontSize: 16,
                onTextMutation: { _ in }
            )
            let coordinator = wrapper.makeCoordinator()
            let layoutManager = NSTextLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 600, height: 400))
            layoutManager.textContainer = container
            controller.textContentStorage.addTextLayoutManager(layoutManager)
            let textView = NativeTextView(
                frame: NSRect(x: 0, y: 0, width: 600, height: 400),
                textContainer: container
            )
            textView.isEditable = true
            coordinator.adopt(textView, text: text.value)

            textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
            #expect(textView.string == "alpha!")
            #expect(text.value == "alpha")
            #expect(coordinator.lastSyncedText == "alpha")

            await drainMainQueue()

            #expect(text.value == "alpha!")
            #expect(coordinator.lastSyncedText == "alpha!")
            #expect(text.bindingWriteCount == 1)
        }

        _ = NSApplication.shared
        await runCase(rawSourceMode: false)
        await runCase(rawSourceMode: true)
    }

    @Test("pending local edits survive mounted rebuild barriers")
    func pendingLocalEditSurvivesMountedRebuilds() async throws {
        @MainActor
        func runCase(
            change: (inout MarkdownEditorConfiguration, inout CGFloat) -> Void
        ) async throws {
            let controller = MarkdownEditorController()
            let text = MutableTextBox("alpha")
            let mutations = MutationBox()
            var configuration = MarkdownEditorConfiguration.default
            var fontSize: CGFloat = 16
            func root() -> MutableAttachmentHost {
                MutableAttachmentHost(
                    text: text,
                    controller: controller,
                    configuration: configuration,
                    fontSize: fontSize,
                    onMutation: { mutations.values.append($0) },
                    onAttachmentChange: { _ in }
                )
            }

            let host = NSHostingView(rootView: root())
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            host.layoutSubtreeIfNeeded()
            let textView = try #require(controller.textView as? NativeTextView)
            let coordinator = try #require(textView.delegate as? NativeTextViewCoordinator)

            textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
            #expect(textView.string == "alpha!")
            #expect(text.value == "alpha")
            #expect(coordinator.lastSyncedText == "alpha")
            #expect(textView.selectedRange() == NSRange(location: 6, length: 0))

            change(&configuration, &fontSize)
            host.rootView = root()
            host.layoutSubtreeIfNeeded()

            #expect(textView.string == "alpha!")
            #expect(text.value == "alpha")
            #expect(coordinator.lastSyncedText == "alpha")
            #expect(text.bindingWriteCount == 0)
            #expect(textView.selectedRange() == NSRange(location: 6, length: 0))
            #expect(mutations.values == [MarkdownTextMutation(
                range: NSRange(location: 5, length: 0),
                replacement: "!"
            )])

            await drainMainQueue()
            #expect(text.value == "alpha!")
            #expect(coordinator.lastSyncedText == "alpha!")
            #expect(text.bindingWriteCount == 1)
        }

        _ = NSApplication.shared
        try await runCase { _, fontSize in fontSize = 17 }
        try await runCase { configuration, _ in configuration.rawSourceMode = true }
        try await runCase { configuration, _ in
            configuration.extensions = [HighlightExtension()]
        }

        if #available(macOS 15.0, *) {
            let controller = MarkdownEditorController()
            let text = MutableTextBox("alpha")
            var configuration = MarkdownEditorConfiguration.default
            func root() -> MutableAttachmentHost {
                MutableAttachmentHost(
                    text: text,
                    controller: controller,
                    configuration: configuration,
                    onMutation: { _ in },
                    onAttachmentChange: { _ in }
                )
            }
            let host = NSHostingView(rootView: root())
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            host.layoutSubtreeIfNeeded()
            let textView = try #require(controller.textView)
            let coordinator = try #require(textView.delegate as? NativeTextViewCoordinator)
            coordinator.textViewWritingToolsWillBegin(textView)
            #expect(textView.shouldChangeText(
                in: NSRange(location: 5, length: 0),
                replacementString: "!"
            ))
            textView.textStorage?.replaceCharacters(
                in: NSRange(location: 5, length: 0),
                with: "!"
            )
            textView.didChangeText()
            coordinator.textViewWritingToolsDidEnd(textView)
            #expect(text.value == "alpha")

            configuration.extensions = [HighlightExtension()]
            host.rootView = root()
            host.layoutSubtreeIfNeeded()
            #expect(textView.string == "alpha!")
            #expect(text.value == "alpha")
            #expect(text.bindingWriteCount == 0)

            await drainMainQueue()
            #expect(text.value == "alpha!")
            #expect(text.bindingWriteCount == 1)
        }
    }

    @Test("pending local authority stays with its mounted identity")
    func pendingLocalEditDoesNotCrossMountedIdentity() async throws {
        _ = NSApplication.shared

        do {
            let controller = MarkdownEditorController()
            let text = MutableTextBox("alpha")
            func root(identity: Int) -> MutableAttachmentHost {
                MutableAttachmentHost(
                    text: text,
                    controller: controller,
                    identity: identity,
                    onMutation: { _ in },
                    onAttachmentChange: { _ in }
                )
            }
            let host = NSHostingView(rootView: root(identity: 1))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            host.layoutSubtreeIfNeeded()
            let outgoing = try #require(controller.textView)
            outgoing.insertText("!", replacementRange: NSRange(location: 5, length: 0))

            host.rootView = root(identity: 2)
            host.layoutSubtreeIfNeeded()
            let replacement = try #require(controller.textView)
            #expect(replacement !== outgoing)
            #expect(replacement.string == "alpha!")
            #expect(text.value == "alpha")
            #expect(text.bindingWriteCount == 0)

            await drainMainQueue()
            #expect(text.value == "alpha")
            #expect(text.bindingWriteCount == 0)
        }

        do {
            let first = MarkdownEditorController()
            let second = MarkdownEditorController()
            let text = MutableTextBox("alpha")
            func root(controller: MarkdownEditorController, documentId: String) -> MutableAttachmentHost {
                MutableAttachmentHost(
                    text: text,
                    controller: controller,
                    documentId: documentId,
                    onMutation: { _ in },
                    onAttachmentChange: { _ in }
                )
            }
            let host = NSHostingView(rootView: root(controller: first, documentId: "first"))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            host.layoutSubtreeIfNeeded()
            let textView = try #require(first.textView)
            textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
            text.value = "alpha!"

            host.rootView = root(controller: second, documentId: "second")
            host.layoutSubtreeIfNeeded()
            #expect(second.textView?.string == "alpha!")

            await drainMainQueue()
            #expect(text.value == "alpha!")
            #expect(text.bindingWriteCount == 0)
        }

        do {
            let controller = MarkdownEditorController()
            let text = MutableTextBox("alpha")
            func root(fontSize: CGFloat = 16) -> MutableAttachmentHost {
                MutableAttachmentHost(
                    text: text,
                    controller: controller,
                    fontSize: fontSize,
                    onMutation: { _ in },
                    onAttachmentChange: { _ in }
                )
            }
            let host = NSHostingView(rootView: root())
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            host.layoutSubtreeIfNeeded()
            let textView = try #require(controller.textView)
            textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
            text.value = "omega"

            host.rootView = root(fontSize: 17)
            host.layoutSubtreeIfNeeded()
            #expect(textView.string == "omega")

            await drainMainQueue()
            #expect(text.value == "omega")
            #expect(text.bindingWriteCount == 0)
        }
    }

    @Test("Find invalidates before every projected client-string change")
    func findInvalidatesAllProjectionChanges() {
        let controller = MarkdownEditorController()
        let responder = TextFinderResponder()
        controller.textFinderActionResponder = responder
        let (textView, coordinator) = view(on: controller, text: "==alpha==\n")
        var projectionBeforeChange: [String] = []
        responder.onStringWillChange = {
            projectionBeforeChange.append(controller.textProjection.string)
            coordinator.notifyTextFinderClientStringWillChange(in: textView)
        }

        textView.insertText("!", replacementRange: NSRange(location: 7, length: 0))
        #expect(projectionBeforeChange == ["==alpha==\n"])

        coordinator.applyExtensionChange([HighlightExtension()], in: textView)
        #expect(projectionBeforeChange == ["==alpha==\n", "==alpha!==\n"])
        #expect(controller.textProjection.string == "alpha!\n")

        coordinator.applyPresentationChange(
            to: true,
            in: textView,
            documentId: "doc",
            text: textView.string
        )
        #expect(projectionBeforeChange.last == "alpha!\n")
        #expect(controller.textProjection.string == "==alpha!==\n")

        coordinator.rebuildTextStorageAndStyle(textView, from: "replacement\n")
        #expect(projectionBeforeChange.last == "==alpha!==\n")

        let countBeforeStyleOnlyChange = responder.stringWillChangeCount
        coordinator.restyleParagraphs(
            [NSRange(location: 0, length: (textView.string as NSString).length)],
            in: textView
        )
        #expect(responder.stringWillChangeCount == countBeforeStyleOnlyChange)
        #expect(responder.stringWillChangeCount == 4)
    }

    @Test("the projection cache follows text and presentation changes")
    func projectionCacheInvalidation() {
        let controller = MarkdownEditorController()
        let (textView, coordinator) = view(on: controller, text: "==alpha==\n")

        #expect(controller.textProjection.string == "==alpha==\n")
        #expect(controller.textProjection.string == "==alpha==\n")

        coordinator.configuration.extensions = [HighlightExtension()]
        #expect(controller.textProjection.string == "alpha\n")

        coordinator.configuration.rawSourceMode = true
        #expect(controller.textProjection.string == "==alpha==\n")

        coordinator.configuration.rawSourceMode = false
        textView.insertText("!", replacementRange: NSRange(location: 7, length: 0))
        #expect(controller.textProjection.string == "alpha!\n")
    }

    // MARK: - A refused view reaches nothing

    private struct TwoViewHost: View {
        let controller: MarkdownEditorController
        let text: String
        let onTextMutation: (MarkdownTextMutation) -> Void
        var body: some View {
            VStack(spacing: 0) {
                NativeTextViewWrapper(text: .constant(text), controller: controller,
                                      fontName: "Helvetica", fontSize: 16,
                                      onTextMutation: onTextMutation)
                NativeTextViewWrapper(text: .constant(text), controller: controller,
                                      fontName: "Helvetica", fontSize: 16,
                                      onTextMutation: onTextMutation)
            }
        }
    }

    /// The composition mistake, mounted: two editors wired to one controller.
    /// The second must stay off the document entirely — not share its storage,
    /// not write its text, not be reachable through it.
    @Test("a mounted second view never joins the document's storage")
    func refusedViewIsIsolated() throws {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        var mutations: [MarkdownTextMutation] = []
        let host = NSHostingView(rootView: TwoViewHost(controller: controller, text: "alpha\n",
                                                       onTextMutation: { mutations.append($0) }))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        host.layoutSubtreeIfNeeded()

        let views = textViews(in: host)
        #expect(views.count == 2)
        let attached = try #require(controller.textView)
        let refused = try #require(views.first { $0 !== attached })

        #expect(controller.textContentStorage.textLayoutManagers.count == 1,
                "the refused view put a second layout manager on the document")
        #expect(refused.textLayoutManager?.textContentManager !== controller.textContentStorage,
                "the refused view is laying out the document it was refused")

        // And it cannot edit the document either: typing in it moves only its
        // own text, and a patch through the controller never reaches it.
        refused.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(attached.string == "alpha\n", "the refused view edited the document")
        #expect(mutations.isEmpty,
                "the refused view published its keystroke as an edit to the document")

        #expect(controller.applyPatch(range: NSRange(location: 0, length: 5),
                                      replacement: "ALPHA"))
        #expect(attached.string == "ALPHA\n")
        #expect(refused.string.hasPrefix("alpha"), "the refused view received the document's edit")
    }

    // MARK: - Remount

    private struct IdentityHost: View {
        let controller: MarkdownEditorController
        let identity: Int
        var body: some View {
            NativeTextViewWrapper(text: .constant("alpha\n"), controller: controller,
                                  fontName: "Helvetica", fontSize: 16)
                .id(identity)
        }
    }

    private struct ControllerSwapHost: View {
        let controller: MarkdownEditorController
        let label: String
        var text = "alpha\n"
        let record: (String) -> Void
        var recordCodeSelection: ((String) -> Void)?

        var body: some View {
            NativeTextViewWrapper(
                text: .constant(text),
                controller: controller,
                fontName: "Helvetica",
                fontSize: 16,
                onAttachmentChange: { textView in
                    record("\(label):\(textView == nil ? "off" : "on")")
                },
                onCodeBlockSelectionChange: { _ in recordCodeSelection?(label) }
            )
        }
    }

    private struct MutableAttachmentHost: View {
        let text: MutableTextBox
        let controller: MarkdownEditorController?
        var configuration: MarkdownEditorConfiguration = .default
        var fontSize: CGFloat = 16
        var documentId = "default"
        var identity: Int?
        let onMutation: (MarkdownTextMutation) -> Void
        let onAttachmentChange: (NSTextView?) -> Void

        var body: some View {
            NativeTextViewWrapper(
                text: Binding(
                    get: { text.value },
                    set: { text.writeFromBinding($0) }
                ),
                configuration: configuration,
                controller: controller,
                fontName: "Helvetica",
                fontSize: fontSize,
                documentId: documentId,
                onAttachmentChange: onAttachmentChange,
                onTextMutation: onMutation
            )
            .id(identity)
        }
    }

    @Test("controller-less wrapper publishes edits")
    func controllerlessWrapperIsLive() throws {
        _ = NSApplication.shared
        let text = MutableTextBox("alpha\n")
        var mutations: [MarkdownTextMutation] = []
        var attachments = 0
        let root = MutableAttachmentHost(
            text: text,
            controller: nil,
            onMutation: { mutation in
                mutations.append(mutation)
                text.apply(mutation)
            },
            onAttachmentChange: { if $0 != nil { attachments += 1 } }
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let textView = try #require(textViews(in: host).first)
        textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        host.rootView = root
        host.layoutSubtreeIfNeeded()

        #expect(attachments == 1)
        #expect(text.value == "alpha!\n")
        #expect(textView.string == "alpha!\n")
        #expect(mutations == [MarkdownTextMutation(
            range: NSRange(location: 5, length: 0),
            replacement: "!"
        )])
    }

    @Test("controller-less wrapper becomes live under a controller")
    func controllerlessWrapperAttachesToFreeController() throws {
        _ = NSApplication.shared
        let text = MutableTextBox("alpha\n")
        let controller = MarkdownEditorController()
        var mutations: [MarkdownTextMutation] = []
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: nil,
            onMutation: { mutation in
                mutations.append(mutation)
                text.apply(mutation)
            },
            onAttachmentChange: { _ in }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        host.rootView = MutableAttachmentHost(
            text: text,
            controller: controller,
            onMutation: { mutation in
                mutations.append(mutation)
                text.apply(mutation)
            },
            onAttachmentChange: { _ in }
        )
        host.layoutSubtreeIfNeeded()
        let textView = try #require(controller.textView)
        textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        #expect(text.value == "alpha!\n")
        #expect(textView.string == "alpha!\n")
        #expect(mutations == [MarkdownTextMutation(
            range: NSRange(location: 5, length: 0),
            replacement: "!"
        )])
    }

    @Test("refused wrapper becomes live under a free controller")
    func refusedWrapperAttachesToFreeController() throws {
        _ = NSApplication.shared
        let occupied = MarkdownEditorController()
        let free = MarkdownEditorController()
        _ = view(on: occupied, text: "alpha\n")
        let text = MutableTextBox("alpha\n")
        var mutations: [MarkdownTextMutation] = []
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: occupied,
            onMutation: { mutation in
                mutations.append(mutation)
                text.apply(mutation)
            },
            onAttachmentChange: { _ in }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        host.rootView = MutableAttachmentHost(
            text: text,
            controller: free,
            onMutation: { mutation in
                mutations.append(mutation)
                text.apply(mutation)
            },
            onAttachmentChange: { _ in }
        )
        host.layoutSubtreeIfNeeded()
        let textView = try #require(free.textView)
        textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        #expect(text.value == "alpha!\n")
        #expect(textView.string == "alpha!\n")
        #expect(mutations == [MarkdownTextMutation(
            range: NSRange(location: 5, length: 0),
            replacement: "!"
        )])
    }

    @Test("controller-backed wrapper becomes controller-less")
    func controllerBackedWrapperBecomesControllerless() throws {
        _ = NSApplication.shared
        let text = MutableTextBox("alpha\n")
        let controller = MarkdownEditorController()
        var mutations: [MarkdownTextMutation] = []
        var attachments: [String] = []
        let mutationHandler: (MarkdownTextMutation) -> Void = { mutation in
            mutations.append(mutation)
            text.apply(mutation)
        }
        let attachmentHandler: (NSTextView?) -> Void = { textView in
            attachments.append(textView == nil ? "off" : "on")
        }
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: controller,
            onMutation: mutationHandler,
            onAttachmentChange: attachmentHandler
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        host.rootView = MutableAttachmentHost(
            text: text,
            controller: nil,
            onMutation: mutationHandler,
            onAttachmentChange: attachmentHandler
        )
        host.layoutSubtreeIfNeeded()
        let textView = try #require(textViews(in: host).first)
        textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        #expect(attachments == ["on", "off", "on"])
        #expect(text.value == "alpha!\n")
        #expect(textView.string == "alpha!\n")
        #expect(mutations == [MarkdownTextMutation(
            range: NSRange(location: 5, length: 0),
            replacement: "!"
        )])
    }

    @Test("refused wrapper becomes controller-less")
    func refusedWrapperBecomesControllerless() throws {
        _ = NSApplication.shared
        let occupied = MarkdownEditorController()
        _ = view(on: occupied, text: "alpha\n")
        let text = MutableTextBox("alpha\n")
        var mutations: [MarkdownTextMutation] = []
        var attachments: [String] = []
        let mutationHandler: (MarkdownTextMutation) -> Void = { mutation in
            mutations.append(mutation)
            text.apply(mutation)
        }
        let attachmentHandler: (NSTextView?) -> Void = { textView in
            attachments.append(textView == nil ? "off" : "on")
        }
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: occupied,
            onMutation: mutationHandler,
            onAttachmentChange: attachmentHandler
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        host.rootView = MutableAttachmentHost(
            text: text,
            controller: nil,
            onMutation: mutationHandler,
            onAttachmentChange: attachmentHandler
        )
        host.layoutSubtreeIfNeeded()
        let textView = try #require(textViews(in: host).first)
        textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        #expect(attachments == ["off", "on"])
        #expect(text.value == "alpha!\n")
        #expect(textView.string == "alpha!\n")
        #expect(mutations == [MarkdownTextMutation(
            range: NSRange(location: 5, length: 0),
            replacement: "!"
        )])
    }

    @Test("controller-less observer detaches before a free controller attaches")
    func controllerlessObserverDetachesBeforeFreeController() throws {
        _ = NSApplication.shared
        let text = MutableTextBox("alpha\n")
        let controller = MarkdownEditorController()
        var events: [String] = []
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: nil,
            onMutation: { text.apply($0) },
            onAttachmentChange: { events.append("N:\($0 == nil ? "off" : "on")") }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        host.rootView = MutableAttachmentHost(
            text: text,
            controller: controller,
            onMutation: { text.apply($0) },
            onAttachmentChange: { events.append("B:\($0 == nil ? "off" : "on")") }
        )
        host.layoutSubtreeIfNeeded()

        #expect(events == ["N:on", "N:off", "B:on"])
        #expect(controller.textView === textViews(in: host).first)
    }

    @Test("controller-less observer detaches before waiting for an occupied controller")
    func controllerlessObserverDetachesBeforeOccupiedController() throws {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let (occupyingView, _) = view(on: controller, text: "bravo\n")
        let text = MutableTextBox("alpha\n")
        var events: [String] = []
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: nil,
            onMutation: { text.apply($0) },
            onAttachmentChange: { events.append("N:\($0 == nil ? "off" : "on")") }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let targetView = try #require(textViews(in: host).first)

        text.value = "bravo\n"
        host.rootView = MutableAttachmentHost(
            text: text,
            controller: controller,
            onMutation: { text.apply($0) },
            onAttachmentChange: { events.append("B:\($0 == nil ? "off" : "on")") }
        )
        host.layoutSubtreeIfNeeded()

        #expect(events == ["N:on", "N:off", "B:off"])
        #expect(controller.textView === occupyingView)
        #expect(targetView.textLayoutManager?.textContentManager !== controller.textContentStorage)

        controller.detach(textView: occupyingView)

        #expect(controller.textView === targetView)
        #expect(events == ["N:on", "N:off", "B:off", "B:on"])
    }

    @Test("controller onAttach is a post-sync mutable boundary")
    func controllerOnAttachCanPatchInitialMount() throws {
        _ = NSApplication.shared
        let text = MutableTextBox("alpha\n")
        let controller = MarkdownEditorController()
        var mutations: [MarkdownTextMutation] = []
        var attachmentCount = 0
        controller.onAttach = { textView in
            guard textView != nil else { return }
            attachmentCount += 1
            #expect(controller.applyPatch(
                range: NSRange(location: 0, length: 5),
                replacement: "ALPHA"
            ))
        }
        let root = MutableAttachmentHost(
            text: text,
            controller: controller,
            onMutation: { mutation in
                mutations.append(mutation)
                text.apply(mutation)
            },
            onAttachmentChange: { _ in }
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        host.rootView = root
        host.layoutSubtreeIfNeeded()

        #expect(attachmentCount == 1)
        #expect(text.value == "ALPHA\n")
        #expect(controller.textView?.string == "ALPHA\n")
        #expect(mutations == [MarkdownTextMutation(
            range: NSRange(location: 0, length: 5),
            replacement: "ALPHA"
        )])
    }

    @Test("wrapper attachment is post-sync after a controller swap")
    func wrapperAttachmentCanPatchControllerSwap() throws {
        _ = NSApplication.shared
        let text = MutableTextBox("alpha\n")
        let first = MarkdownEditorController()
        let second = MarkdownEditorController()
        var mutations: [MarkdownTextMutation] = []
        var events: [String] = []
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: first,
            onMutation: { mutation in
                mutations.append(mutation)
                text.apply(mutation)
            },
            onAttachmentChange: { _ in }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        second.onAttach = { textView in
            if textView != nil { events.append("controller") }
        }
        let secondRoot = MutableAttachmentHost(
            text: text,
            controller: second,
            onMutation: { mutation in
                mutations.append(mutation)
                text.apply(mutation)
            },
            onAttachmentChange: { textView in
                guard textView != nil else { return }
                events.append("wrapper")
                #expect(second.applyPatch(
                    range: NSRange(location: 0, length: 5),
                    replacement: "ALPHA"
                ))
            }
        )
        host.rootView = secondRoot
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        host.rootView = secondRoot
        host.layoutSubtreeIfNeeded()

        #expect(events == ["controller", "wrapper"])
        #expect(text.value == "ALPHA\n")
        #expect(second.textView?.string == "ALPHA\n")
        #expect(mutations == [MarkdownTextMutation(
            range: NSRange(location: 0, length: 5),
            replacement: "ALPHA"
        )])
    }

    @Test("reentrant teardown does not publish a late wrapper attachment")
    func controllerAttachmentCanTearDownSynchronously() {
        _ = NSApplication.shared
        let text = MutableTextBox("alpha\n")
        let controller = MarkdownEditorController()
        var wrapperAttachments: [Bool] = []
        controller.onAttach = { textView in
            guard let textView else { return }
            controller.detach(textView: textView)
        }
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: controller,
            onMutation: { _ in },
            onAttachmentChange: { wrapperAttachments.append($0 != nil) }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        #expect(!controller.isAttached)
        #expect(wrapperAttachments.isEmpty)
    }

    @Test("a controller swap detaches through the outgoing callback")
    func controllerSwapKeepsAttachmentCallbacksBoundToTheirDocument() throws {
        _ = NSApplication.shared
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        var events: [String] = []
        let host = NSHostingView(rootView: ControllerSwapHost(
            controller: documentA,
            label: "A",
            record: { events.append($0) }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        _ = try #require(documentA.textView)
        #expect(events == ["A:on"])

        host.rootView = ControllerSwapHost(
            controller: documentB,
            label: "B",
            record: { events.append($0) }
        )
        host.layoutSubtreeIfNeeded()

        _ = try #require(documentB.textView)
        #expect(events == ["A:on", "A:off", "B:on"])
    }

    @Test("an occupied controller swap takes over when the target frees")
    func occupiedControllerSwapTakesOverWithoutAnotherUpdate() throws {
        _ = NSApplication.shared
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        let (occupyingView, _) = view(on: documentB, text: "bravo\n")
        let text = MutableTextBox("alpha\n")
        var events: [String] = []
        var mutationsA: [MarkdownTextMutation] = []
        var mutationsB: [MarkdownTextMutation] = []
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: documentA,
            onMutation: { mutationsA.append($0) },
            onAttachmentChange: { events.append("A:\($0 == nil ? "off" : "on")") }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let targetView = try #require(documentA.textView)

        text.value = "bravo\n"
        func targetRoot() -> MutableAttachmentHost {
            MutableAttachmentHost(
                text: text,
                controller: documentB,
                onMutation: { mutation in
                    mutationsB.append(mutation)
                    text.apply(mutation)
                },
                onAttachmentChange: { events.append("B:\($0 == nil ? "off" : "on")") }
            )
        }
        host.rootView = targetRoot()
        host.layoutSubtreeIfNeeded()

        #expect(documentA.textView == nil)
        #expect(documentB.textView === occupyingView)
        #expect(targetView.string == "bravo\n")
        #expect(targetView.textLayoutManager?.textContentManager !== documentA.textContentStorage)
        #expect(targetView.textLayoutManager?.textContentManager !== documentB.textContentStorage)
        #expect(events == ["A:on", "A:off", "B:off"])

        host.rootView = targetRoot()
        host.layoutSubtreeIfNeeded()
        #expect(documentA.textView == nil)
        #expect(documentB.textView === occupyingView)
        #expect(targetView.string == "bravo\n")
        #expect(events == ["A:on", "A:off", "B:off"])

        targetView.insertText("?", replacementRange: NSRange(location: 5, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        #expect(targetView.string == "bravo?\n")
        #expect(text.value == "bravo\n")
        #expect(mutationsA.isEmpty)
        #expect(mutationsB.isEmpty)

        #expect(documentB.applyPatch(
            range: NSRange(location: 0, length: 5),
            replacement: "BRAVO"
        ))
        #expect(occupyingView.string == "BRAVO\n")
        #expect(text.value == "bravo\n")
        #expect(mutationsB.isEmpty)

        documentB.detach(textView: occupyingView)

        #expect(documentB.textView === targetView)
        #expect(targetView.textLayoutManager?.textContentManager === documentB.textContentStorage)
        #expect(targetView.string == "BRAVO\n")
        #expect(text.value == "bravo\n")
        #expect(documentB.textContentStorage.textLayoutManagers.count == 1)
        #expect(events == ["A:on", "A:off", "B:off", "B:on"])
        #expect(mutationsB.isEmpty)
        #expect(text.bindingWriteCount == 0)

        host.rootView = targetRoot()
        host.layoutSubtreeIfNeeded()
        #expect(targetView.string == "BRAVO\n")
        #expect(text.value == "bravo\n")
        #expect(documentB.textContentStorage.textLayoutManagers.count == 1)
        #expect(events == ["A:on", "A:off", "B:off", "B:on"])
        #expect(mutationsB.isEmpty)
        #expect(text.bindingWriteCount == 0)

        text.value = "BRAVO\n"
        host.rootView = targetRoot()
        host.layoutSubtreeIfNeeded()
        #expect(targetView.string == "BRAVO\n")
        #expect(mutationsB.isEmpty)
        #expect(text.bindingWriteCount == 0)

        text.value = "BRAVO!\n"
        host.rootView = targetRoot()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        #expect(targetView.string == "BRAVO!\n")
        #expect(text.value == "BRAVO!\n")
        #expect(documentB.textContentStorage.textLayoutManagers.count == 1)
        #expect(events == ["A:on", "A:off", "B:off", "B:on"])
        #expect(mutationsB.isEmpty)
        #expect(text.bindingWriteCount == 0)

        targetView.insertText("?", replacementRange: NSRange(location: 6, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        #expect(text.value == "BRAVO!?\n")
        #expect(targetView.string == "BRAVO!?\n")
        #expect(mutationsA.isEmpty)
        #expect(mutationsB == [MarkdownTextMutation(
            range: NSRange(location: 6, length: 0),
            replacement: "?"
        )])
    }

    @Test("an occupied swap can free the target from its detached callback")
    func occupiedControllerSwapHandlesReentrantRelease() throws {
        _ = NSApplication.shared
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        let (occupyingView, _) = view(on: documentB, text: "bravo\n")
        let text = MutableTextBox("alpha\n")
        var events: [String] = []
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: documentA,
            onMutation: { _ in },
            onAttachmentChange: { events.append("A:\($0 == nil ? "off" : "on")") }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let targetView = try #require(documentA.textView)

        text.value = "bravo\n"
        host.rootView = MutableAttachmentHost(
            text: text,
            controller: documentB,
            onMutation: { text.apply($0) },
            onAttachmentChange: { textView in
                events.append("B:\(textView == nil ? "off" : "on")")
                if textView == nil {
                    documentB.detach(textView: occupyingView)
                }
            }
        )
        host.layoutSubtreeIfNeeded()

        #expect(documentA.textView == nil)
        #expect(documentB.textView === targetView)
        #expect(targetView.textLayoutManager?.textContentManager === documentB.textContentStorage)
        #expect(targetView.string == "bravo\n")
        #expect(events == ["A:on", "A:off", "B:off", "B:on"])
    }

    @Test("an occupied swap restores the target document selection after takeover")
    func occupiedControllerSwapRestoresTargetSelection() throws {
        _ = NSApplication.shared
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        let host = NSHostingView(rootView: ControllerSwapHost(
            controller: documentB,
            label: "B",
            text: "bravo\n",
            record: { _ in }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let targetView = try #require(documentB.textView)
        targetView.setSelectedRange(NSRange(location: 3, length: 0))

        host.rootView = ControllerSwapHost(
            controller: documentA,
            label: "A",
            text: "alpha\n",
            record: { _ in }
        )
        host.layoutSubtreeIfNeeded()
        let (occupyingView, _) = view(on: documentB, text: "bravo\n")

        host.rootView = ControllerSwapHost(
            controller: documentB,
            label: "B",
            text: "bravo\n",
            record: { _ in }
        )
        host.layoutSubtreeIfNeeded()

        documentB.detach(textView: occupyingView)

        #expect(documentB.textView === targetView)
        #expect(targetView.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test("outgoing wrapper callback can free the occupied target before admission")
    func outgoingCallbackCanFreeOccupiedTarget() throws {
        _ = NSApplication.shared
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        let (occupyingView, _) = view(on: documentB, text: "bravo\n")
        #expect(documentB.applyPatch(
            range: NSRange(location: 0, length: 5),
            replacement: "BRAVO"
        ))
        let text = MutableTextBox("alpha\n")
        var events: [String] = []
        var attachedTexts: [String] = []
        documentB.onAttach = { textView in
            events.append("B-controller:\(textView == nil ? "off" : "on")")
            if let textView { attachedTexts.append(textView.string) }
        }
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: documentA,
            onMutation: { _ in },
            onAttachmentChange: { textView in
                events.append("A:\(textView == nil ? "off" : "on")")
                if textView == nil {
                    documentB.detach(textView: occupyingView)
                }
            }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let targetView = try #require(documentA.textView)

        text.value = "bravo\n"
        func targetRoot() -> MutableAttachmentHost {
            MutableAttachmentHost(
                text: text,
                controller: documentB,
                onMutation: { text.apply($0) },
                onAttachmentChange: { textView in
                    events.append("B:\(textView == nil ? "off" : "on")")
                    if let textView { attachedTexts.append(textView.string) }
                }
            )
        }
        host.rootView = targetRoot()
        host.layoutSubtreeIfNeeded()

        #expect(documentA.textView == nil)
        #expect(documentB.textView === targetView)
        #expect(targetView.textLayoutManager?.textContentManager === documentB.textContentStorage)
        #expect(documentB.textContentStorage.textLayoutManagers.count == 1)
        #expect(targetView.string == "BRAVO\n")
        #expect(text.value == "bravo\n")
        #expect(attachedTexts == ["BRAVO\n", "BRAVO\n"])
        #expect(events == ["A:on", "A:off", "B-controller:off", "B-controller:on", "B:on"])

        host.rootView = targetRoot()
        host.layoutSubtreeIfNeeded()

        #expect(targetView.string == "BRAVO\n")
        #expect(text.value == "bravo\n")
        #expect(attachedTexts == ["BRAVO\n", "BRAVO\n"])
        #expect(events == ["A:on", "A:off", "B-controller:off", "B-controller:on", "B:on"])

        text.value = "BRAVO\n"
        host.rootView = targetRoot()
        host.layoutSubtreeIfNeeded()
        #expect(targetView.string == "BRAVO\n")

        text.value = "BRAVO!\n"
        host.rootView = targetRoot()
        host.layoutSubtreeIfNeeded()
        #expect(targetView.string == "BRAVO!\n")
        #expect(attachedTexts == ["BRAVO\n", "BRAVO\n"])
        #expect(events == ["A:on", "A:off", "B-controller:off", "B-controller:on", "B:on"])
    }

    @Test("outgoing wrapper callback can occupy a free target before admission")
    func outgoingCallbackCanOccupyFreeTarget() throws {
        _ = NSApplication.shared
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        let text = MutableTextBox("alpha\n")
        var blocker: (NativeTextView, NativeTextViewCoordinator)?
        var events: [String] = []
        var mutationsB: [MarkdownTextMutation] = []
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: documentA,
            onMutation: { _ in },
            onAttachmentChange: { textView in
                events.append("A:\(textView == nil ? "off" : "on")")
                if textView == nil {
                    blocker = view(on: documentB, text: "bravo\n")
                }
            }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let targetView = try #require(documentA.textView)

        text.value = "bravo\n"
        host.rootView = MutableAttachmentHost(
            text: text,
            controller: documentB,
            onMutation: { mutation in
                mutationsB.append(mutation)
                text.apply(mutation)
            },
            onAttachmentChange: { events.append("B:\($0 == nil ? "off" : "on")") }
        )
        host.layoutSubtreeIfNeeded()
        let blockingView = try #require(blocker?.0)

        #expect(documentA.textView == nil)
        #expect(documentB.textView === blockingView)
        #expect(documentB.textContentStorage.textLayoutManagers.count == 1)
        #expect(targetView.textLayoutManager?.textContentManager !== documentB.textContentStorage)
        #expect(events == ["A:on", "A:off", "B:off"])

        targetView.insertText("?", replacementRange: NSRange(location: 5, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        #expect(text.value == "bravo\n")
        #expect(blockingView.string == "bravo\n")
        #expect(mutationsB.isEmpty)

        documentB.detach(textView: blockingView)

        #expect(documentB.textView === targetView)
        #expect(targetView.string == "bravo\n")
        #expect(documentB.textContentStorage.textLayoutManagers.count == 1)
        #expect(events == ["A:on", "A:off", "B:off", "B:on"])

        targetView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        #expect(text.value == "bravo!\n")
        #expect(mutationsB == [MarkdownTextMutation(
            range: NSRange(location: 5, length: 0),
            replacement: "!"
        )])
    }

    @Test("a waiter survives one callback reoccupation")
    func waiterSurvivesCallbackReoccupation() throws {
        _ = NSApplication.shared
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        let (occupyingView, _) = view(on: documentB, text: "bravo\n")
        let text = MutableTextBox("alpha\n")
        var replacement: (NativeTextView, NativeTextViewCoordinator)?
        var didReoccupy = false
        var events: [String] = []
        let host = NSHostingView(rootView: MutableAttachmentHost(
            text: text,
            controller: documentA,
            onMutation: { _ in },
            onAttachmentChange: { events.append("A:\($0 == nil ? "off" : "on")") }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let targetView = try #require(documentA.textView)

        text.value = "bravo\n"
        host.rootView = MutableAttachmentHost(
            text: text,
            controller: documentB,
            onMutation: { text.apply($0) },
            onAttachmentChange: { events.append("B:\($0 == nil ? "off" : "on")") }
        )
        host.layoutSubtreeIfNeeded()
        documentB.onAttach = { textView in
            if textView == nil && !didReoccupy {
                didReoccupy = true
                replacement = view(on: documentB, text: "bravo\n")
            }
        }

        documentB.detach(textView: occupyingView)
        let replacementView = try #require(replacement?.0)
        #expect(documentB.textView === replacementView)
        #expect(targetView.textLayoutManager?.textContentManager !== documentB.textContentStorage)
        #expect(events == ["A:on", "A:off", "B:off"])

        documentB.detach(textView: replacementView)

        #expect(documentB.textView === targetView)
        #expect(targetView.textLayoutManager?.textContentManager === documentB.textContentStorage)
        #expect(events == ["A:on", "A:off", "B:off", "B:on"])
    }

    @Test("selection-derived callbacks switch before the incoming document rebuilds")
    func controllerSwapUsesIncomingSelectionCallbacks() throws {
        _ = NSApplication.shared
        let source = "```swift\nlet value = 1\n```\n"
        let documentA = MarkdownEditorController()
        let documentB = MarkdownEditorController()
        var codeSelectionLabels: [String] = []
        let host = NSHostingView(rootView: ControllerSwapHost(
            controller: documentA,
            label: "A",
            text: source,
            record: { _ in },
            recordCodeSelection: { codeSelectionLabels.append($0) }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        codeSelectionLabels.removeAll()

        host.rootView = ControllerSwapHost(
            controller: documentB,
            label: "B",
            text: source,
            record: { _ in },
            recordCodeSelection: { codeSelectionLabels.append($0) }
        )
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        _ = try #require(documentB.textView)
        #expect(!codeSelectionLabels.isEmpty)
        #expect(codeSelectionLabels.allSatisfy { $0 == "B" },
                "the incoming document published through the outgoing callback: \(codeSelectionLabels)")
    }

    /// SwiftUI builds a remount's replacement BEFORE dismantling the original
    /// and sends the replacement no further update pass — measured order:
    /// `make(new) → update(new) → dismantle(old)`. So the new view is refused at
    /// build time and can never re-ask. Releasing the controller has to hand it
    /// over, or a remount leaves a live editor that reaches nothing: no
    /// `applyPatch`, no text-view seam, no find, no typewriter scrolling.
    @Test("a remount hands the controller to the replacement view")
    func remountHandsOverTheController() throws {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let host = NSHostingView(rootView: IdentityHost(controller: controller, identity: 1))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let original = try #require(controller.textView)

        host.rootView = IdentityHost(controller: controller, identity: 2)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let attached = try #require(controller.textView, "the remounted view was orphaned")
        #expect(attached !== original)
        #expect(textViews(in: host).contains { $0 === attached },
                "the attached view is not the one on screen")
        #expect(controller.textContentStorage.textLayoutManagers.count == 1)
        // And it is a working editor, not merely a registered one.
        #expect(controller.applyPatch(range: NSRange(location: 0, length: 5),
                                      replacement: "ALPHA"))
        #expect(attached.string == "ALPHA\n")
    }

    @Test("a remount exposes authoritative text before Finder attaches")
    func remountFinderSeesAuthoritativeText() throws {
        _ = NSApplication.shared
        let controller = MarkdownEditorController()
        let host = NSHostingView(rootView: IdentityHost(controller: controller, identity: 1))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        _ = try #require(controller.textView)
        #expect(controller.applyPatch(
            range: NSRange(location: 0, length: 5),
            replacement: "ALPHA"
        ))

        let responder = TextFinderResponder()
        var attachedProjections: [String] = []
        controller.onAttach = { textView in
            guard textView != nil else { return }
            attachedProjections.append(controller.textProjection.string)
            controller.textFinderActionResponder = responder
        }

        host.rootView = IdentityHost(controller: controller, identity: 2)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        #expect(controller.textProjection.string == "ALPHA\n")
        #expect(attachedProjections == ["ALPHA\n"])
        #expect(responder.stringWillChangeCount == 0)
    }

    // MARK: - Two windows, the supported way

    /// Two windows on one document are two controllers, each with its own
    /// storage, kept in step by forwarding each one's `onTextMutation` into the
    /// other's `applyPatch`. In the app that forwarding is `DocumentSession`'s
    /// patch stream; here it is four lines, which is the point — the engine
    /// needs nothing but the two halves it already has.
    @Test("two controllers stay in sync when their edits are forwarded")
    func twoControllersStayInSync() {
        let left = MarkdownEditorController()
        let right = MarkdownEditorController()
        let source = "alpha bravo charlie\n"
        let (leftView, leftCoordinator) = view(on: left, text: source)
        let (rightView, rightCoordinator) = view(on: right, text: source)

        // The bridge: one side's edit descriptor applied to the other, with a
        // re-entrancy guard so the echo stops there.
        var forwarding = false
        func bridge(_ from: NativeTextViewCoordinator, to other: MarkdownEditorController) {
            from.onTextMutation = { mutation in
                guard !forwarding else { return }
                forwarding = true
                defer { forwarding = false }
                other.applyPatch(range: mutation.range, replacement: mutation.replacement)
            }
        }
        bridge(leftCoordinator, to: right)
        bridge(rightCoordinator, to: left)

        leftView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(leftView.string == "alpha! bravo charlie\n")
        #expect(rightView.string == "alpha! bravo charlie\n",
                "the second window did not receive the first's edit")

        rightView.insertText("?", replacementRange: NSRange(location: 12, length: 0))
        #expect(rightView.string == "alpha! bravo? charlie\n")
        #expect(leftView.string == "alpha! bravo? charlie\n",
                "the first window did not receive the second's edit")

        // Separate storages, separate carets — which is what makes two windows
        // worth having.
        #expect(leftView.textContentStorage !== rightView.textContentStorage)
        leftView.setSelectedRange(NSRange(location: 2, length: 0))
        rightView.setSelectedRange(NSRange(location: 14, length: 0))
        #expect(leftView.selectedRange() == NSRange(location: 2, length: 0))
        #expect(rightView.selectedRange() == NSRange(location: 14, length: 0))
    }
}

//
//  MarkdownEditorController+Revision.swift
//  MarkdownEngine
//

import AppKit

struct MarkdownDocumentMutationRecord {
    let revision: UInt64
    let mutation: MarkdownTextMutation?
    let mutationDelta: Int
    let documentLength: Int
}

@MainActor
private final class MarkdownDocumentRevisionState {
    private(set) var revision: UInt64 = 0
    private(set) var mutationDelta = 0
    private(set) var publishedDelta = 0
    private var records: [MarkdownDocumentMutationRecord] = []

    func record(
        _ mutation: MarkdownTextMutation?,
        mutationDelta: Int,
        documentLength: Int
    ) {
        revision &+= 1
        self.mutationDelta += mutationDelta
        if mutation != nil {
            publishedDelta += mutationDelta
        }
        records.append(MarkdownDocumentMutationRecord(
            revision: revision,
            mutation: mutation,
            mutationDelta: mutationDelta,
            documentLength: documentLength
        ))
        if records.count > 4_096 {
            records.removeFirst(records.count - 4_096)
        }
    }

    func records(after revision: UInt64) -> [MarkdownDocumentMutationRecord]? {
        if let first = records.first, revision &+ 1 < first.revision {
            return nil
        }
        return records.filter { $0.revision > revision }
    }
}

@MainActor
private enum MarkdownDocumentRevisionStore {
    static let states = NSMapTable<NSTextContentStorage, MarkdownDocumentRevisionState>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    static func state(for storage: NSTextContentStorage) -> MarkdownDocumentRevisionState {
        if let state = states.object(forKey: storage) {
            return state
        }
        let state = MarkdownDocumentRevisionState()
        states.setObject(state, forKey: storage)
        return state
    }
}

@MainActor
extension MarkdownEditorController {
    var documentRevision: UInt64 {
        MarkdownDocumentRevisionStore.state(for: textContentStorage).revision
    }

    var documentMutationDelta: Int {
        MarkdownDocumentRevisionStore.state(for: textContentStorage).mutationDelta
    }

    var documentPublishedDelta: Int {
        MarkdownDocumentRevisionStore.state(for: textContentStorage).publishedDelta
    }

    func recordDocumentMutation(
        _ mutation: MarkdownTextMutation?,
        mutationDelta: Int,
        documentLength: Int
    ) {
        MarkdownDocumentRevisionStore.state(for: textContentStorage)
            .record(
                mutation,
                mutationDelta: mutationDelta,
                documentLength: documentLength
            )
    }

    func documentMutationRecords(
        after revision: UInt64
    ) -> [MarkdownDocumentMutationRecord]? {
        MarkdownDocumentRevisionStore.state(for: textContentStorage)
            .records(after: revision)
    }
}

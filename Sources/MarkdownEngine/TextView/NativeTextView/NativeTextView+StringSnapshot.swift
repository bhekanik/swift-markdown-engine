//
//  NativeTextView+StringSnapshot.swift
//  MarkdownEngine
//
//  `NSTextView.string` bridges a fresh copy of the whole storage on every read
//  (≈0.7 ms for a 200k-character document), and one keystroke reads it about a
//  dozen times across the coordinator, the wrapper and the embedder. The view
//  keeps one native copy until the storage's characters change, so repeat reads
//  are free and equality checks against it are a pointer or byte compare.
//

import AppKit

/// Counts character edits to one storage. Attribute-only edits (restyling) do
/// not invalidate a snapshot of the text.
final class TextStorageCharacterGeneration {
    let storage: NSTextStorage
    private(set) var value: UInt64 = 0
    private var token: NSObjectProtocol?

    init(storage: NSTextStorage) {
        self.storage = storage
        token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { [weak self] notification in
            guard let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            self?.value &+= 1
        }
    }

    isolated deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

struct TextViewStringSnapshot {
    let generation: UInt64
    let text: String
}

extension NativeTextView {
    /// The storage's text, served from the snapshot while no character edit
    /// has landed since it was taken.
    ///
    /// Mid-batch (inside `beginEditing`/`endEditing`, or while the storage is
    /// still processing an edit) the characters have changed but the
    /// generation has not moved yet, so those reads bypass the snapshot.
    func snapshotString() -> String {
        guard let storage = textStorage else { return super.string }
        if characterGeneration?.storage !== storage {
            characterGeneration = TextStorageCharacterGeneration(storage: storage)
            stringSnapshot = nil
        }
        guard let generation = characterGeneration,
              !storage.editedMask.contains(.editedCharacters) else {
            return super.string
        }
        if let snapshot = stringSnapshot, snapshot.generation == generation.value {
            return snapshot.text
        }
        // A lone surrogate has no native (UTF-8) form; decoding would repair it
        // to U+FFFD and break UTF-16 exactness, so such text is never cached.
        guard let text = Self.nativeCopy(of: storage.mutableString) else {
            return super.string
        }
        stringSnapshot = TextViewStringSnapshot(generation: generation.value, text: text)
        return text
    }

    /// One bulk UTF-16 read and one transcode. `makeContiguousUTF8()` on the
    /// bridged string walks the storage a character at a time through
    /// `characterAtIndex:`, which costs more than every read it would save.
    private static func nativeCopy(of source: NSString) -> String? {
        let length = source.length
        guard length > 0 else { return "" }
        let units = UnsafeMutableBufferPointer<unichar>.allocate(capacity: length)
        defer { units.deallocate() }
        source.getCharacters(units.baseAddress!, range: NSRange(location: 0, length: length))
        guard isWellFormed(units) else { return nil }
        return String(decoding: units, as: UTF16.self)
    }

    /// Every high surrogate is followed by a low one and no low one stands
    /// alone. (`String(validating:as:)` does this but needs macOS 15.)
    private static func isWellFormed(_ units: UnsafeMutableBufferPointer<unichar>) -> Bool {
        var index = 0
        let count = units.count
        while index < count {
            let unit = units[index]
            if UTF16.isLeadSurrogate(unit) {
                guard index + 1 < count, UTF16.isTrailSurrogate(units[index + 1]) else { return false }
                index += 2
            } else if UTF16.isTrailSurrogate(unit) {
                return false
            } else {
                index += 1
            }
        }
        return true
    }
}

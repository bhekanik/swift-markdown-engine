//
//  MarkdownTextDiff.swift
//  MarkdownEngine
//
//  The one changed run between two documents, as a patch.
//

import Foundation

public extension MarkdownTextPatch {
    /// The single contiguous run that differs between `old` and `new`.
    ///
    /// A common prefix/suffix scan, not a real diff: a document edit is one
    /// contiguous change often enough that the extra machinery would buy
    /// nothing, and an over-wide answer is still correct output — a bigger
    /// restyle, never a wrong document.
    ///
    /// The scan walks **Unicode scalars**, not UTF-16 code units, and the
    /// result is converted to a UTF-16 `NSRange` at the end. Reconciling
    /// `A😀Z` to `A😂Z` over code units puts the emoji's shared high surrogate
    /// in the common prefix and builds a replacement out of the lone low
    /// surrogate: the text storage reassembles the right document from the
    /// units, but the ``MarkdownTextMutation`` handed to the embedder holds
    /// half a character and is not valid UTF-8, so a sync outbox that
    /// JSON-encodes it fails. Scalar alignment is what stops that.
    static func diff(from old: String, to new: String) -> MarkdownTextPatch {
        let oldScalars = Array(old.unicodeScalars)
        let newScalars = Array(new.unicodeScalars)

        var prefix = 0
        let maxPrefix = min(oldScalars.count, newScalars.count)
        while prefix < maxPrefix, oldScalars[prefix] == newScalars[prefix] { prefix += 1 }

        var suffix = 0
        let maxSuffix = maxPrefix - prefix
        while suffix < maxSuffix,
              oldScalars[oldScalars.count - 1 - suffix] == newScalars[newScalars.count - 1 - suffix] {
            suffix += 1
        }

        let removed = oldScalars[prefix..<(oldScalars.count - suffix)]
        let inserted = newScalars[prefix..<(newScalars.count - suffix)]
        let location = utf16Length(oldScalars[0..<prefix])
        return MarkdownTextPatch(
            range: NSRange(location: location, length: utf16Length(removed)),
            replacement: String(String.UnicodeScalarView(inserted))
        )
    }

    private static func utf16Length(_ scalars: ArraySlice<Unicode.Scalar>) -> Int {
        scalars.reduce(0) { $0 + UTF16.width($1) }
    }
}

extension NSString {
    /// Whether `offset` falls between the two halves of a surrogate pair.
    ///
    /// `NSRange` addresses UTF-16 code units and an emoji is two of them, so a
    /// range boundary can land inside one character. Every range that reaches
    /// the storage from outside is checked against this.
    func splitsSurrogatePair(at offset: Int) -> Bool {
        guard offset > 0, offset < length else { return false }
        let before = character(at: offset - 1)
        let after = character(at: offset)
        return UTF16.isLeadSurrogate(before) && UTF16.isTrailSurrogate(after)
    }
}

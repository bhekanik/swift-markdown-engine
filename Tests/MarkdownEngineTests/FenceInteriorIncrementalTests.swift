//
//  FenceInteriorIncrementalTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 12.07.26.
//
//  Typing INSIDE a fenced code block used to bail the incremental block parse
//  (full O(doc) reparse every keystroke). The window splice now handles
//  interior edits. Broad differential coverage lives in the pre-existing
//  ParseIncrementalEquivalenceTests fuzz.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Fence-interior incremental parse")
struct FenceInteriorIncrementalTests {

    private func chars(_ s: String) -> [unichar] {
        let ns = s as NSString
        var buf = [unichar](repeating: 0, count: ns.length)
        if ns.length > 0 { ns.getCharacters(&buf, range: NSRange(location: 0, length: ns.length)) }
        return buf
    }

    private func splice(_ old: String, at loc: Int, remove: Int, insert: String)
        -> (new: String, diff: BufferDiff) {
        let ns = NSMutableString(string: old)
        ns.replaceCharacters(in: NSRange(location: loc, length: remove), with: insert)
        let insertLen = (insert as NSString).length
        return (ns as String, BufferDiff(
            changeStart: loc,
            changeEndOld: loc + remove,
            changeEndNew: loc + insertLen,
            delta: insertLen - remove
        ))
    }

    /// nil = splice bailed to full parse (also correct); true/false = blocks match.
    private func spliceEqualsFullParse(_ old: String, at loc: Int, remove: Int, insert: String) -> Bool? {
        let (new, diff) = splice(old, at: loc, remove: remove, insert: insert)
        guard let result = BlockParser.incrementalParse(
            oldChars: chars(old), oldBlocks: BlockParser.computeBlocks(old),
            newChars: chars(new), newNS: new as NSString, diff: diff
        ) else { return nil }
        return result.blocks == BlockParser.computeBlocks(new)
    }

    @Test func interiorFenceEditSplicesIncrementally() {
        let old = "para one\n\n```swift\nlet x = 1\nlet y = 2\n```\n\ntail paragraph"
        let editLoc = (old as NSString).range(of: "x = 1").location
        #expect(spliceEqualsFullParse(old, at: editLoc, remove: 1, insert: "value") == true)
    }

}

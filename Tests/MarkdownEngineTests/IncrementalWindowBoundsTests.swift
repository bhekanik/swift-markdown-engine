//
//  IncrementalWindowBoundsTests.swift
//  MarkdownEngineTests
//
//  The reparse window grows until its trailing block cannot be reinterpreted by
//  the suffix. Every growth reparses the window from its start, so a document
//  whose blocks are all context-sensitive — alternating list items and
//  blockquote lines — never reaches a stable trailing block, the window walks to
//  the end, and the whole thing is quadratic. Measured at 370 ms per keystroke
//  on a 10 kB chain against an 8 ms budget.
//
//  Giving up is the fix: past a bound, one full parse is cheaper than
//  continuing. These hold both halves of that — the bound fires, and whatever
//  path is taken still produces exactly the blocks a full parse would.
//

import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Incremental window bounds")
struct IncrementalWindowBoundsTests {

    /// Blocks that each absorb the line after them, so the window can never
    /// settle.
    private func alternatingChain(pairs: Int) -> String {
        var out = "# Notes\n\n"
        for index in 0..<pairs {
            out += "- item \(index)\n"
            out += "> quoted \(index)\n"
        }
        return out
    }

    private func blocks(_ text: String) -> [Block] {
        BlockParser.computeBlocks(text)
    }

    /// The splice, asked directly, so the test is about the bound rather than
    /// about whatever the memo happens to hold.
    private func splice(from old: String, to new: String) -> [Block]? {
        let oldChars = Array(old.utf16)
        let newChars = Array(new.utf16)
        guard let diff = BlockParser.scanDiff(old: oldChars, new: newChars) else { return nil }
        return BlockParser.incrementalParse(
            oldChars: oldChars,
            oldBlocks: blocks(old),
            newChars: newChars,
            newNS: new as NSString,
            diff: diff
        )?.blocks
    }

    @Test("an unstable chain gives up instead of walking the document")
    func unstableChainRefusesToSplice() {
        let old = alternatingChain(pairs: 400)
        let range = (old as NSString).range(of: "item 200")
        let new = (old as NSString).replacingCharacters(in: range, with: "item 200x")

        #expect(splice(from: old, to: new) == nil,
                "the window kept extending; every extension reparses from its start")
    }

    @Test("giving up still yields exactly what a full parse yields")
    func fullParseAgreesAfterGivingUp() {
        let old = alternatingChain(pairs: 400)
        let range = (old as NSString).range(of: "item 200")
        let new = (old as NSString).replacingCharacters(in: range, with: "item 200x")

        // What the caller does when the splice declines.
        let full = blocks(new)
        #expect(full.count > 700)
        var cursor = 0
        for block in full {
            #expect(block.range.location == cursor, "the full parse must tile the document")
            cursor = NSMaxRange(block.range)
        }
        #expect(cursor == (new as NSString).length)
    }

    @Test("a short chain still splices — the bound is a ceiling, not a ban")
    func shortChainStillSplices() throws {
        let old = alternatingChain(pairs: 3)
        let range = (old as NSString).range(of: "item 1")
        let new = (old as NSString).replacingCharacters(in: range, with: "item 1x")

        let spliced = try #require(splice(from: old, to: new),
                                   "a three-pair chain is well inside the bound")
        #expect(spliced == blocks(new), "the splice disagreed with a full parse")
    }

    @Test("an ordinary document is unaffected by the bound")
    func ordinaryDocumentStillSplices() throws {
        var old = ""
        for index in 0..<200 {
            old += "## Section \(index)\n\nSome prose about sediment and silt.\n\n"
        }
        let range = (old as NSString).range(of: "Section 100")
        let new = (old as NSString).replacingCharacters(in: range, with: "Section 100x")

        let spliced = try #require(splice(from: old, to: new))
        #expect(spliced == blocks(new))
    }

    @Test("a window larger than the byte bound declines rather than splicing")
    func oversizedWindowDeclines() {
        // One paragraph bigger than the window ceiling: the edit's own block
        // cannot fit, so there is nothing to splice around.
        let paragraph = String(repeating: "sediment settles into layers. ", count: 900)
        let old = paragraph + "\n"
        let new = "x" + paragraph + "\n"
        #expect((old as NSString).length > 16_384)

        #expect(splice(from: old, to: new) == nil)
        // And the full parse of the result is still well-formed.
        #expect(blocks(new).count >= 1)
    }
}

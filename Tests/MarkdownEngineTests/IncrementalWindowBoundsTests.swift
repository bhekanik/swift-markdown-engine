//
//  IncrementalWindowBoundsTests.swift
//  MarkdownEngineTests
//
//  The reparse window grows until its trailing block cannot be reinterpreted by
//  the suffix, and every growth reparses the window from its START — so a shape
//  that never settles makes the whole thing quadratic. An alternating chain of
//  list items and blockquote lines measured 370 ms per keystroke on 10 kB,
//  against an 8 ms budget.
//
//  Two things fix it, and both are held here. The stability test asks whether
//  the line that actually FOLLOWS can change the trailing block, rather than
//  assuming any block of a context-sensitive KIND might grow — a blockquote
//  line cannot continue a list, so that chain settles at once. And a bound on
//  extensions and window size backstops whatever shape still walks: past it the
//  splice declines and the caller does one full parse, which at that size costs
//  about the same and cannot mis-splice.
//

import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Incremental window bounds")
struct IncrementalWindowBoundsTests {

    /// Blocks that alternate between two kinds, neither of which can continue
    /// the other.
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

    /// The splice, asked directly, so the test is about the window rather than
    /// about whatever the memo happens to be holding.
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

    /// Every splice must produce exactly the block list a full parse produces.
    private func expectAgreesWithFullParse(_ spliced: [Block], _ text: String) {
        #expect(spliced == blocks(text), "the splice disagreed with a full parse")
        var cursor = 0
        for block in spliced {
            #expect(block.range.location == cursor, "blocks must tile the document")
            cursor = NSMaxRange(block.range)
        }
        #expect(cursor == (text as NSString).length)
    }

    @Test("an alternating list/blockquote chain settles at once and splices")
    func alternatingChainSplices() throws {
        // The shape that used to walk the whole document on every keystroke.
        let old = alternatingChain(pairs: 400)
        let range = (old as NSString).range(of: "item 200")
        let new = (old as NSString).replacingCharacters(in: range, with: "item 200x")

        let spliced = try #require(splice(from: old, to: new),
                                   "the window failed to settle on a shape that cannot grow")
        expectAgreesWithFullParse(spliced, new)
    }

    @Test("a window past the byte bound declines rather than splicing")
    func oversizedWindowDeclines() {
        // One paragraph larger than the ceiling: the edit's own block does not
        // fit, so there is nothing to splice around.
        let paragraph = String(repeating: "sediment settles into layers. ", count: 900)
        let old = paragraph + "\n"
        let new = "x" + paragraph + "\n"
        #expect((old as NSString).length > 16_384)

        #expect(splice(from: old, to: new) == nil)

        // And the full parse the caller falls back to is well formed.
        let full = blocks(new)
        var cursor = 0
        for block in full {
            #expect(block.range.location == cursor)
            cursor = NSMaxRange(block.range)
        }
        #expect(cursor == (new as NSString).length)
    }

    @Test("a genuinely growing trailing block still extends the window")
    func growingTrailingBlockStillExtends() throws {
        // A paragraph followed by a setext underline: the window MUST reach the
        // `---` or it splices a paragraph plus a thematic break where a full
        // parse gives an H2.
        let old = "intro\n\nTitle\n---\n\nbody\n"
        let range = (old as NSString).range(of: "intro")
        let new = (old as NSString).replacingCharacters(in: range, with: "introx")

        let spliced = try #require(splice(from: old, to: new))
        expectAgreesWithFullParse(spliced, new)
        #expect(spliced.contains { $0.kind == .heading },
                "the setext heading was lost to a too-narrow window")
    }

    @Test("a short chain still splices — the bound is a ceiling, not a ban")
    func shortChainStillSplices() throws {
        let old = alternatingChain(pairs: 3)
        let range = (old as NSString).range(of: "item 1")
        let new = (old as NSString).replacingCharacters(in: range, with: "item 1x")

        let spliced = try #require(splice(from: old, to: new))
        expectAgreesWithFullParse(spliced, new)
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
        expectAgreesWithFullParse(spliced, new)
    }
}

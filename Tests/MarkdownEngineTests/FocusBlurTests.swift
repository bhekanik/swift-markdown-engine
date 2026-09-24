//
//  FocusBlurTests.swift
//  MarkdownEngineTests
//

import CoreGraphics
import Testing
@testable import MarkdownEngine

@Suite("Focus blur radius")
struct FocusBlurTests {
    /// A 30 pt caret line at y 300…330, full blur 6 pt over 180 pt.
    private let blur = MarkdownFocusBlur(lineMinY: 300, lineMaxY: 330, maximumRadius: 6, rampDistance: 180)

    private func radius(line index: Int) -> CGFloat {
        let minY = 300 + CGFloat(index) * 30
        return blur.radius(lineMinY: minY, lineMaxY: minY + 30)
    }

    @Test("the caret's line is sharp; every other line blurs, more with distance")
    func curve() {
        #expect(radius(line: 0) == 0)
        let below = (1...8).map { radius(line: $0) }
        let above = (1...8).map { radius(line: -$0) }
        #expect(below == above, "symmetric")
        #expect(below.first! >= 6 * 0.3, "a neighbour starts at a third of full strength")
        #expect(below == below.sorted(), "never less blur further away")
        #expect(below.last == 6, "full strength once the ramp is walked")
    }

    @Test("a blank line touching the caret's still blurs a little")
    func touchingLineBlurs() {
        // The caret on a blank line: the text line right above touches it.
        #expect(blur.radius(lineMinY: 270, lineMaxY: 300) > 0)
    }

    @Test("radii come in quarter-point steps, so cached lines are reused")
    func quantised() {
        for index in 1...10 {
            let value = radius(line: index) * 4
            #expect(value == value.rounded())
        }
    }
}

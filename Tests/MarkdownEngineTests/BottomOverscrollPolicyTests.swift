//
//  BottomOverscrollPolicyTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 11.06.26.
//
//  Bottom-overscroll math.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("BottomOverscrollPolicy")
struct BottomOverscrollPolicyTests {

    /// Engine defaults: percent 0.5, max 450, min 40, activation 0.15 + 0.85.
    private let policy = BottomOverscrollPolicy(configuration: .default)
    private let visible: CGFloat = 800
    private let lineHeight: CGFloat = 26

    @Test func shortTextWithoutBandGetsNoSlack() {
        // Below the activation start (0.15 × 800 = 120): nothing to scroll.
        let slack = policy.activeOverscroll(
            baseContentHeight: 100, visibleHeight: visible, lineHeight: lineHeight
        )
        #expect(slack == 0)
    }

    @Test func emptyDocumentWithoutBandGetsNoSlack() {
        let slack = policy.activeOverscroll(
            baseContentHeight: 30, visibleHeight: visible, lineHeight: lineHeight
        )
        #expect(slack == 0)
    }

    @Test func headerlessRampMatchesPreBandBehavior() {
        // Locks the formula:
        // progress = (500 − 120) / 680, unlock = 300, slack = 374
        // → floor((300 + 374) × 0.55882…) = 376.
        let slack = policy.activeOverscroll(
            baseContentHeight: 500, visibleHeight: visible, lineHeight: lineHeight
        )
        #expect(slack == 376)
    }
}

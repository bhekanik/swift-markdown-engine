// swift-tools-version: 6.2
import PackageDescription

// MarkdownEngine — a TextKit-2 backed Markdown editor view for macOS.
//
// Embedders import `MarkdownEngine` and supply their own adapters that
// conform to the engine's service protocols (`EmbeddedImageProvider`,
// `SyntaxHighlighter`). The engine has zero external dependencies.
//
// Recto fork: the turnkey `MarkdownEngineCodeBlocks` / `MarkdownEngineLatex`
// products are gone along with their HighlighterSwift and SwiftMath
// dependencies. SwiftPM resolved and cloned both even for a dependent that
// only used the core `MarkdownEngine` product, so they were a real cost.
let engineSettings: [SwiftSetting] = [
    // The engine is a main-thread AppKit/TextKit-2 component end to end:
    // every entry point is a delegate callback, a SwiftUI update pass or a
    // draw. Its hot paths memoise in mutable statics (BlockParser's buffer
    // cache, the tokenizer's per-block memos, the table bitmap caches), which
    // under Swift 6 concurrency checking are only sound because they are
    // main-actor. `defaultIsolation` states that once instead of annotating
    // ~200 declarations. Swift 6 language mode makes that isolation part of
    // the module's enforced public contract.
    .defaultIsolation(MainActor.self),
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "MarkdownEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownEngine", targets: ["MarkdownEngine"]),
    ],
    targets: [
        .target(name: "MarkdownEngine", swiftSettings: engineSettings),
        .testTarget(
            name: "MarkdownEngineTests",
            dependencies: ["MarkdownEngine"],
            swiftSettings: engineSettings
        )
    ]
)

<p align="center">                                                                                               
<img width="128" alt="SwiftMarkdownEngine logo" src="media/logo.png" />
</p>

<h1 align="center">SwiftMarkdownEngine</h1>  

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white" alt="Swift 5.9+" /></a>
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/Platforms-macOS%2014+-lightgrey" alt="Platforms macOS 14+" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-yellow.svg" alt="License: Apache 2.0" /></a>
  <a href="https://github.com/nodes-app/swift-markdown-engine/actions/workflows/ci.yml"><img src="https://github.com/nodes-app/swift-markdown-engine/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
</p>



<video src="https://github.com/user-attachments/assets/b61ed622-0e9a-4e91-9de5-9cd6c53752e5"
       autoplay loop muted playsinline
       width="100%">
</video>


A native AppKit Markdown editor for macOS, built on TextKit 2 and bridged to SwiftUI. It is the editor inside **[Nodes](https://apps.apple.com/app/apple-store/id6745401961?pt=127809373&ct=github&mt=8)**, a macOS notes app. Live styling, fenced code blocks with syntax highlighting, and GitHub-style task
checkboxes.

## Features

- **Live Markdown styling** — bold, italic, headings, lists, blockquotes, GFM tables, code, links, task checkboxes, horizontal rules
- **Code blocks** with embedder-supplied syntax highlighting and overlayable
  copy buttons
- **Reading column** — opt-in fixed-width centered column, wide tables
  break out to the full window width (`readingWidth`)
- **TextKit 2** layout for accurate, modern text rendering
- **Writing Tools** integration on macOS 15.1+
- **Comfortable bottom overscroll** so the caret never pins to the viewport
  edge while typing
- **Drag-select autoscroll boost** for long documents
- **Spelling & grammar** with code suppression
- **Extensions** — opt-in constructs defined by a *delimiter pair* (`==highlight==`, `~~strikethrough~~`, …); add your own via [`MarkdownExtension`](#extensions)

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/nodes-app/swift-markdown-engine", from: "0.1.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
        ]
    )
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repo URL.

The package ships one library product:

| Product | Use when |
|---|---|
| `MarkdownEngine` | You want the editor only. Zero external dependencies. |

## Quick Start

```swift
import SwiftUI
import MarkdownEngine

struct EditorScreen: View {
    @State private var text: String = "# Hello, *world*"

    var body: some View {
        NativeTextViewWrapper(text: $text)
    }
}
```

That's it. See [Customization](#customization) below for syntax
highlighting, themes, and more.

> **Displaying multiple editors?** Pass a stable, unique
> `documentId: "your-doc-id"` so undo history stays scoped to each editor
> instance.

## Customization

### Service Protocols

The engine talks to your app through a service protocol with
a no-op default so you only implement what you actually need:

| Protocol | What you supply | Ready-made bridge / suggested library |
|---|---|---|
| `SyntaxHighlighter` | Highlight code blocks for a given language | (your highlighter) |

The protocol and its no-op default are documented in DocC.

### Theming

Every color the editor puts on screen reads from `MarkdownEditorTheme`:

```swift
var theme = MarkdownEditorTheme.default
theme.bodyText = .labelColor
theme.findMatchHighlight = NSColor(named: "MyAccent")!

var configuration = MarkdownEditorConfiguration.default
configuration.theme = theme
```

Defaults map to `NSColor` dynamic system colors, so light/dark mode
keeps working without extra code.

### Tuning

`MarkdownEditorConfiguration` exposes every spacing / sizing / behavior
knob the engine has, grouped by concern:

```swift
var configuration = MarkdownEditorConfiguration.default
configuration.codeBlock.fontSizeScale = 0.9
configuration.headings.fontMultipliers = [2.4, 1.8, 1.4, 1.1, 0.9, 0.75]
configuration.overscroll.percent = 0.4
configuration.lists.helpersEnabled = false
configuration.safeAreaInsets = SafeAreaInsets(top: 56)   // headroom under a translucent toolbar
```

### Height Behavior

By default the editor scrolls internally. Set `heightBehavior` to
`.fitsContent` to make it grow to fit its content and report that height to
SwiftUI, so an enclosing `ScrollView` scrolls the page instead:

```swift
ScrollView {
    NativeTextViewWrapper(text: $text, configuration: .init(heightBehavior: .fitsContent))
}
```

Composes with `readingWidth` and is switchable at
runtime. `.fitsContent` lays out the whole document (no viewport
virtualization), so prefer it for small-to-medium content. See
``HeightBehavior`` in DocC for the full behavior.

### Reading Column

Give long documents a fixed-width centered column; wide GFM tables break out
to the full window width, Google-Docs-style:

```swift
configuration.readingWidth = 650
```

Text wraps at `readingWidth` and never re-wraps on resize (only the column's
position moves), keeping live resize smooth. Leave it `nil` (default) to fill
the container edge-to-edge.

### Extensions

An extension is **a pair of delimiters** plus how to style what sits between
them. The core engine parses pure markdown; constructs like
`==highlight==`, `~~strikethrough~~`, and `::: … :::` container blocks are
opt-in extensions:

```swift
var config = MarkdownEditorConfiguration()
config.extensions = [HighlightExtension(), StrikethroughExtension(), ContainerExtension()]
```

Unregistered syntax stays literal text. An extension contributes an inline
form (`InlineSyntax`), a fenced block form (`BlockSyntax`), or both — plus the
attributes for its content and an HTML wrapper for rich copy. The parser owns
all geometry, marker/fence hiding, caret reveal, and incremental restyling, so
extensions behave identically to built-ins and cannot affect neighboring
constructs. Conform to `MarkdownExtension` to add your own.

## Demo

A runnable SwiftUI demo lives in [`Demo/`](Demo/MarkdownEngineDemo.xcodeproj).
Open it in Xcode and hit **Run** — the demo references the package via
a local path, so any engine edit rebuilds into the demo on the next run.

> If you're seeing a "missing package product" error, it's almost always
> stale package cache. Use **File → Packages → Reset Package Caches**
> once and rebuild.

## Documentation

Full API docs ship as DocC. In Xcode: **Product → Build Documentation**
(`⇧⌃⌘D`); for local CLI preview see [CONTRIBUTING.md](CONTRIBUTING.md). Once
hosted on Swift Package Index, docs will live at
`https://swiftpackageindex.com/nodes-app/swift-markdown-engine/documentation`.

## Requirements & Status

- macOS 14 or later (15.1+ for Apple Writing Tools integration)
- Swift 5.9 / Xcode 15 or later

MarkdownEngine is currently **pre-1.0**. The public API may change between
minor releases as it stabilizes. Production use is fine — pin a specific
version (`0.x.y`) in your `Package.swift`.

## Who makes it

<a href="https://apps.apple.com/app/apple-store/id6745401961?pt=127809373&ct=github&mt=8">
  <img align="right" width="96" alt="Nodes" src="media/nodes-app-icon.png" />
</a>

MarkdownEngine is the editor inside **[Nodes](https://apps.apple.com/app/apple-store/id6745401961?pt=127809373&ct=github&mt=8)**,
a macOS app for writing, linking and exploring notes. This is not a side project
we open-sourced and walked away from — it is the editor our own users type in
every day, and every fix here ships in a real app first.

If it is useful to you, telling someone about it is all we would ask for.

## Contributing

Bug reports, ideas, and pull requests are welcome.

- [ARCHITECTURE.md](ARCHITECTURE.md) — codemap and pipeline guide for
  contributors
- [CONTRIBUTING.md](CONTRIBUTING.md) — setup, PR process, and design
  constraints

## License

MarkdownEngine is released under the Apache 2.0 License. See [LICENSE](LICENSE)
for the full text.

---
Built by a small team in Munich and Zurich. Day-to-day on [Instagram](https://www.instagram.com/nodes.app).

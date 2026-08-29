//
//  ContentView.swift
//  MarkdownEngine
//
//  Created by Nicolas von Mallinckrodt on 29.04.26.
//

import SwiftUI
import MarkdownEngine

struct ContentView: View {
    @State private var text: String = sampleMarkdown

    // Engine modes, flipped live from the toolbar.
    @State private var isReadOnly = false
    @State private var showRawSource = false
    @State private var useReadingColumn = false

    /// Registers/unregisters the opt-in seam. The document is written
    /// so that flipping this off is the whole explanation of what is core
    /// markdown and what is not: Part 2 falls back to literal text, while Part 1
    /// doesn't move a pixel.
    @State private var seamsEnabled = true

    // Base font size; all relative sizing (headings, code) tracks it.
    @State private var fontSize: CGFloat = 16

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            fontSize: fontSize,
            isEditable: !isReadOnly,
            placeholder: NSAttributedString(
                string: "Empty document — start typing, markdown styles live…",
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        )
        // `readingWidth` is applied when the underlying NSView is built, so
        // flipping the reading column recreates the editor via `.id`. The
        // `text` binding survives; scroll position resets — fine for a demo.
        .id(useReadingColumn)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $isReadOnly) {
                    Label("Read-only", systemImage: isReadOnly ? "lock" : "lock.open")
                }
                .help("Read-only: the styled document stays scrollable and selectable, editing is off")

                Toggle(isOn: $showRawSource) {
                    Label("Raw source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("Raw markdown source: no styling, no syntax hiding")

                Toggle(isOn: $useReadingColumn) {
                    Label("Reading column", systemImage: "arrow.right.and.line.vertical.and.arrow.left")
                }
                .help("Centered fixed-width reading column — wide tables still break out to full width")

                Toggle(isOn: $seamsEnabled) {
                    Label("Opt-in seams", systemImage: "puzzlepiece.extension")
                }
                .help("Register/unregister the extensions of Part 2 — everything they contribute falls back to literal text")

                ControlGroup {
                    Button {
                        fontSize = max(10, fontSize - 2)
                    } label: {
                        Label("Smaller text", systemImage: "textformat.size.smaller")
                    }
                    .disabled(fontSize <= 10)

                    Button {
                        fontSize = min(28, fontSize + 2)
                    } label: {
                        Label("Larger text", systemImage: "textformat.size.larger")
                    }
                    .disabled(fontSize >= 28)
                }
                .help("Base font size — headings and code scale relative to it")
            }
        }
    }

    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default

        // The opt-in seam (Part 2 of the document). The core engine does not know
        // `==highlight==` or `~~strikethrough~~`; these two extensions supply
        // them.
        config.extensions = seamsEnabled ? [HighlightExtension(), StrikethroughExtension()] : []

        // Toolbar-driven modes.
        config.rawSourceMode = showRawSource
        config.readingWidth = useReadingColumn ? 620 : nil

        return config
    }
}

/// Builds the demo markdown shown when the editor first loads.
///
/// Ordered in two parts by WHERE a construct comes from, because that is the
/// question a reader of this demo actually has:
///
///   Part 1  core markdown — link `MarkdownEngine`, done
///   Part 2  opt-in seams — registered in `MarkdownEditorConfiguration`
private var sampleMarkdown: String {
    [
        markdownHeader,
        corePartHeader,
        inlineFormattingSection,
        blocksSection,
        codeSection,
        taskListSection,
        tableSection,
        seamsPartHeader,
        extensionSection,
        markdownFooter,
    ].joined(separator: "\n\n")
}

// MARK: - Part dividers

private let corePartHeader = """
---

# Part 1 · Core markdown

Everything under this heading is the engine itself — no registration, no extra \
package products. Link `MarkdownEngine` and you have all of it. Neither toolbar \
toggle below changes a single character of this part.
"""

private let seamsPartHeader = """
---

# Part 2 · Opt-in seams

Nothing below is markdown. Every construct here exists only because something \
was registered in `MarkdownEditorConfiguration` — and unregistered, the exact \
same characters are literal text.

**Flip “Opt-in seams” off in the toolbar** and watch this part collapse into \
plain text while Part 1 stays put. That is the whole distinction.
"""

/// Blockquote + list demo: quotes keep inline styling; lists auto-continue
/// on Return, renumber, and change nesting with Tab / Shift-Tab.
private let blocksSection = """
## Blockquotes & lists

> Blockquotes keep full **inline** styling — and quote markers hide like every other marker.

Lists auto-continue on Return; Tab and Shift-Tab move the nesting level:

- Unordered lists
  - nest two spaces per level
    - up to three levels deep

1. Ordered lists renumber as you edit
2. and auto-continue too
"""

/// Task-list demo: click a checkbox to toggle it. The glyphs are SF Symbols;
/// embedders can swap them via `TaskCheckboxStyle` (`config.taskCheckbox`).
private let taskListSection = """
## Task lists

- [x] Draw checkboxes as SF Symbols
- [ ] Click a box to toggle it
- [ ] Ship it
"""

/// Extension seam demo: `==highlight==` and `~~strikethrough~~` are NOT part
/// of the core grammar anymore — they're supplied by the opt-in
/// `HighlightExtension` and `StrikethroughExtension` registered above.
private let extensionSection = """
## Extensions — delimiter-shaped

`config.extensions = [HighlightExtension(), StrikethroughExtension()]`

An extension is a PAIR OF DELIMITERS plus how to style what's between them. \
This ==highlighted text== comes from `HighlightExtension`, this \
~~struck-through text~~ from `StrikethroughExtension`. Nesting works like any \
core construct: ==with *italic* inside== and ~~also *nested*~~.

Turn the seams off and both sentences above keep their `==` and `~~` as \
ordinary characters — the core grammar has never heard of them.
"""

/// Table layout demo: the first table's cells WRAP to the available width
/// (CSS auto-layout style); the second has so many columns that even the
/// longest-word minimums don't fit — it stays wide and scrolls horizontally.
private let tableSection = """
## Tables

Cells wrap to the available width:

| Novel | Opening line |
|---|---|
| Der Zauberberg (1924) | "Ein einfacher junger Mensch reiste im Hochsommer von Hamburg, seiner Vaterstadt, nach Davos-Platz im Graubündischen." |
| The Master and Margarita (1966–67) | "At the sunset hour of one warm spring day two men were to be seen at Patriarch's Ponds." (trans. Michael Glenny) |
| The Picture of Dorian Gray (1890) | "The studio was filled with the rich odour of roses, and when the light summer wind stirred amidst the trees of the garden, there came through the open door the heavy scent of the lilac, or the more delicate perfume of the pink-flowering thorn." |

Too many columns → horizontal scroll instead of crushed cells:

| Movement | Landmark novel | Narrative signature | Characteristic preoccupations | Philosophical undercurrents | Contemporaneous reception | Posthumous reputation | Author | Structural device | Central symbol | Typical setting | Enduring influence |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Modernism | Der Zauberberg | Essayistic time-dilation | Sanatorium cosmopolitanism | Schopenhauer-inflected pessimism | Immediate bestseller | Cornerstone of literary modernism | Thomas Mann | Bildungsroman inversion | The mountain as timeless enclosure | Alpine sanatorium | Shaped the European novel of ideas |
| Menippean satire | The Master and Margarita | Novel-within-a-novel | Cowardice and censorship | Faustian epigraph | Suppressed, samizdat-circulated | Perennial Russian favorite | Mikhail Bulgakov | Interleaved dual narratives | The devil as satirical mirror | Soviet Moscow and biblical Jerusalem | Model for satire under censorship |
| Aestheticism | The Picture of Dorian Gray | Epigrammatic wit | Portrait-as-conscience | Paterian hedonism | Scandalized reviewers | Perpetually adapted | Oscar Wilde | Portrait as moral ledger | The aging portrait | Fin de siècle London | Touchstone for art for art’s sake |
"""

private let markdownHeader = """
# MarkdownEngine

A native macOS Markdown editor built on **TextKit 2**, bridged to SwiftUI — brought to you by [nodes-web.com](https://nodes-web.com).

Edit this text live. Formatting updates as you type — and the toolbar flips engine modes at runtime: read-only, raw markdown source, a centered reading column, and the opt-in seams.

This document is ordered by WHERE each construct comes from, because that is the thing worth knowing before you adopt any of it:

1. **Core markdown** — link `MarkdownEngine`, nothing else to do.
2. **Opt-in seams** — registered in your configuration. Unregistered, the same characters are literal text.
"""

/// Inline formatting demo — core only.
private let inlineFormattingSection = """
## Inline formatting

Mix **bold**, *italic*, and ***both at once***. Reach for `inline code` when a short snippet helps.
"""

private let codeSection = #"""
    ## Code

    Swift:

    ```swift
    import SwiftUI
    import MarkdownEngine

    struct Editor: View {
        @State private var text = "# Hello"

        var body: some View {
            NativeTextViewWrapper(text: $text)
                .frame(minWidth: 640, minHeight: 480)
        }
    }
    ```

"""#

private let markdownFooter = """
---

"""

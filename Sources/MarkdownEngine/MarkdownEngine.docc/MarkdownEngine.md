# ``MarkdownEngine``

A TextKit 2-backed Markdown editor view for macOS, bridged to SwiftUI.

## Overview

MarkdownEngine provides a native AppKit Markdown editor with live styling,
fenced code blocks with syntax highlighting, and GitHub-style task checkboxes.

The engine itself has **zero external dependencies**. Everything app-specific
is injected through a service protocol, so embedders stay in control of how
code is highlighted.

### Quick Start

```swift
import SwiftUI
import MarkdownEngine

struct EditorScreen: View {
    @State private var text: String = "# Hello, *world*"
    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: .default,
            fontName: "SF Pro",
            documentId: "doc-1"
        )
    }
}
```

The default ``MarkdownEditorConfiguration`` ships with no-op service
implementations, so the editor renders plain Markdown out of the box. Add
real services as you need them.

### Customizing Appearance

```swift
var theme = MarkdownEditorTheme.default
theme.bodyText = .labelColor
theme.headingMarker = .secondaryLabelColor

var configuration = MarkdownEditorConfiguration.default
configuration.theme = theme
```

### Wiring Up Services

```swift
let services = MarkdownEditorServices(syntaxHighlighter: MySyntaxHighlighter())

var configuration = MarkdownEditorConfiguration.default
configuration.services = services
```

## Topics

### Editor View

- ``NativeTextViewWrapper``

### Configuration

- ``MarkdownEditorConfiguration``
- ``MarkdownEditorTheme``

### Service Protocols

- ``SyntaxHighlighter``

### Services Container

- ``MarkdownEditorServices``
- ``MarkdownEditorBus``

### Default No-Op Implementations

- ``PlainTextSyntaxHighlighter``

### Selection

- ``CodeBlockSelection``

//
//  NativeTextViewCoordinator+Restyling.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Re-tokenization and paragraph-scoped restyling. The TextDelegate extension decides WHEN and on WHICH ranges to
//  restyle; this extension owns the tokenize cache and the actual call into
//  `TextStylingService`.
//

import AppKit

extension NativeTextViewCoordinator {
    /// Atomically rebuilds contents + base attrs + Markdown styling from `text`.
    func rebuildTextStorageAndStyle(
        _ textView: NSTextView,
        from text: String,
        invalidateLayout: Bool = false,
        notifyTextFinder: Bool = true
    ) {
        // Suppress the re-entrant textViewDidChangeSelection that `textView.string =`
        // and the setAttributedString transfer below fire synchronously (71ms of
        // redundant styling on a 346k note); the necessary side effect is replayed once
        // at the end of this method.
        isRebuildingDocument = true
        defer { isRebuildingDocument = false }
        // A rebuild means a different document (or a mode flip): drop the caret
        // ink resolved for the old one instead of carrying it into this text.
        resolvedCaretColor = nil
        let rawMode = configuration.rawSourceMode

        // Claimed BEFORE the assignment: `textView.string =` re-enters
        // textViewDidChangeSelection synchronously, whose updateCodeBlockSelection
        // laid out the whole (still unstyled) document — 141ms / 7714 fragments that
        // the ensureLayout below rebuilds from scratch anyway. This rebuild's own
        // ensureLayout IS that one-shot per-document layout.
        didEnsureLayoutForCurrentDocument = true
        if textView.string != text {
            if notifyTextFinder {
                notifyTextFinderClientStringWillChange(in: textView)
            }
            textView.string = text
            parseGeneration &+= 1
        }
        lastSyncedText = text
        previousDisplayLength = (text as NSString).length
        let nsDisplay = text as NSString
        // Fresh document baseline: drop the incremental parse state and reseed
        // the backtick census (a stale count from the previous document would
        // force a spurious full-document restyle on the first keystroke).
        parseState.invalidate()
        pendingBacktickWindow = nil
        backtickCensusNeedsRescan = false
        previousBacktickCount = MarkdownDetection.tripleBacktickCount(in: nsDisplay)
        let fullRange = NSRange(location: 0, length: nsDisplay.length)

        let (baseFont, paragraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )
        let baseAttrs = TextStylingService.makeBaseAttributes(
            font: baseFont, paragraphStyle: paragraph, configuration: configuration)
        // ── Root cause & fix (2026-07) ────────────────────────────────────────
        // CPU+page-fault instrumentation proved the first per-process open of a large
        // note spent 12.5s of PURE CPU (blocked=2ms), writing 69k attributes to the LIVE
        // TextKit-2 storage and faulting in 315k pages / ~5GB; a later open with warm
        // pages does the identical work in 78ms. So the whole styled string is built on a
        // DETACHED NSMutableAttributedString and handed to the live storage in ONE
        // transfer — the expensive first-touch happens off the layout-connected storage.
        let built = NSMutableAttributedString(string: text)
        built.setAttributes(baseAttrs, range: fullRange)

        // Kept for the end-of-rebuild selection replay (see below); raw mode leaves it nil.
        var parsedForReplay: ParsedDocument?
        if rawMode {
            // Base attributes only — the source stays verbatim and unstyled.
            activeTokenIndices = []
        } else {
            let parsed = parsedDocument(for: text)
            parsedForReplay = parsed
            let tokens = parsed.tokens
            // Hide caret from styling when read-only, else clicks reveal raw token syntax.
            let caretLocation = textView.isEditable ? textView.selectedRange().location : -1
            activeTokenIndices = activeTokenIndices(
                parsed: parsed,
                selection: textView.selectedRange(),
                in: nsDisplay,
                suppressed: !textView.isEditable
            )

            let ranges = MarkdownStyler.styleAttributes(
                text: text,
                fontName: fontName,
                fontSize: fontSize,
                layoutBridge: layoutBridge,
                caretLocation: caretLocation,
                // Selection-revealed syntax (task checkboxes) needs the full
                // range, not just the caret; read-only suppresses it like the caret.
                selection: textView.isEditable ? textView.selectedRange() : nil,
                activeTokenIndices: activeTokenIndices,
                precomputedTokens: tokens,
                classified: parsed.classified,
                // Same parse the tokens came from; without it the styler ran the
                // block parser a SECOND time over the whole document per open.
                precomputedBlocks: parsed.blocks,
                configuration: configuration
            )
            // scoped=nil is the point: the rebuild passes no scopedRanges, so
            // every token in the document is styled.

            // ROOT CAUSE (proven by a CPU sample of the 12.5–16s first-open hang):
            // per-key `addAttribute` creates a short-lived intermediate dict on every
            // call (the run's dict grows one key at a time), each interned into
            // Foundation's global WEAK NSAttributeDictionary table. Each intermediate
            // dies at the next add, leaving a weak tombstone, so the next insert triggers
            // `-[NSConcreteHashTable rehashAround:]` to compact — O(table) per insert,
            // quadratic overall, amplified by the app's large heap (expensive objc weak
            // ops). Coalescing to non-overlapping runs and writing each with ONE
            // `setAttributes` interns exactly one LIVE dict per run — no intermediates, no
            // tombstones, no rehash thrash. First open dropped from 16s to tens of ms.
            let runs = MarkdownStyler.flattenedRuns(ranges, base: baseAttrs,
                                                    documentLength: fullRange.length)
            for (range, attrs) in runs {
                built.setAttributes(attrs, range: range)
            }
        }

        // ONE live-storage mutation carries the whole styled document across. This is the
        // only edit that touches the layout-connected storage.
        textView.textStorage?.beginEditing()
        textView.textStorage?.setAttributedString(built)
        textView.textStorage?.endEditing()


        textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraph,
            theme: configuration.theme
        )

        if let tlm = textView.textLayoutManager {
            if invalidateLayout {
                tlm.invalidateLayout(for: tlm.documentRange)
            }
            tlm.ensureLayout(for: tlm.documentRange)
        }

        // The re-entrant textViewDidChangeSelection was suppressed for this rebuild
        // (isRebuildingDocument), so replay the one selection-derived side effect nothing
        // else runs afterwards: spell/grammar/quote toggles for the loaded caret. Also seed
        // the selection bookkeeping the next real selection change diffs against, so it
        // starts from the loaded document instead of the previous one's stale caret. Raw
        // mode / active Writing Tools skip both, exactly as the suppressed handler's own
        // rawSourceMode / isWritingToolsActive early-returns would have.
        if let parsed = parsedForReplay, !isWritingToolsActive {
            let finalSelection = textView.selectedRange()
            updateAutocorrectSettings(
                textView,
                caretLocation: finalSelection.location,
                codeTokens: parsed.codeTokens,
                allTokens: parsed.tokens
            )
            previousActiveTokenIndices = activeTokenIndices
            previousCaretLocation = finalSelection.location
            previousSelectedRange = finalSelection
        }

        // Reconcile wide-table overlays after layout settles.
        if let nativeTextView = textView as? NativeTextView {
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
    }

    func applyExtensionChange(
        _ extensions: [any MarkdownExtension],
        in textView: NSTextView
    ) {
        var updated = configuration
        updated.extensions = extensions
        guard updated.extensionRegistry.fingerprint != configuration.extensionRegistry.fingerprint
        else { return }

        notifyTextFinderClientStringWillChange(in: textView)
        configuration.extensions = extensions
        (textView as? NativeTextView)?.configuration.extensions = extensions
        cachedParsedDocument = nil
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        if fullRange.length > 0 {
            restyleParagraphs([fullRange], in: textView)
        }
    }

    func notifyTextFinderClientStringWillChange(in textView: NSTextView) {
        guard editorController?.textView === textView,
              !isNotifyingTextFinderClientStringChange else { return }
        isNotifyingTextFinderClientStringChange = true
        editorController?.textFinderActionResponder?.textFinderClientStringWillChange()
        isNotifyingTextFinderClientStringChange = false
    }

    func restyleTextView(
        _ textView: NSTextView,
        paragraphCandidates: [NSRange],
        tokens: [MarkdownToken]? = nil,
        classified: MarkdownStyler.ClassifiedStyleTokens? = nil,
        blocks: [Block]? = nil
    ) {
        // Raw mode: no restyling; typing keeps base attrs via the typing shim.
        guard !configuration.rawSourceMode else { return }
        let (baseFont, paragraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )

        TextStylingService.restyle(
            textView: textView,
            layoutBridge: layoutBridge,
            paragraphCandidates: paragraphCandidates,
            baseFont: baseFont,
            paragraphStyle: paragraphStyle,
            caretLocation: textView.isEditable ? textView.selectedRange().location : -1,
            // Selection-revealed task syntax: this is the per-keystroke /
            // selection-change restyle path, so the styler needs the full
            // selected range here too (read-only suppresses it like the caret).
            selection: textView.isEditable ? textView.selectedRange() : nil,
            activeTokenIndices: activeTokenIndices,
            precomputedTokens: tokens,
            classified: classified,
            precomputedBlocks: blocks,
            configuration: configuration
        )
        // Reconcile wide-table overlays after layout settles.
        if let nativeTextView = textView as? NativeTextView {
            DispatchQueue.main.async { [weak nativeTextView] in
                nativeTextView?.updateWideTableOverlays()
            }
        }
    }

    func parsedDocument(for text: String, edit: ParseEditDescriptor? = nil) -> ParsedDocument {
        let length = (text as NSString).length
        if let cachedParsedDocument, cachedParsedLength == length {
            // O(1) hit: nothing has edited the storage since the cached parse.
            if cachedParseGeneration == parseGeneration { return cachedParsedDocument }
            // Generation moved but the text may still be identical (e.g. an
            // attribute-only pass): confirm via NSString.isEqual (a byte
            // compare — the bridged Swift `==` walked 139k chars per keystroke).
            if let cachedParsedText, (cachedParsedText as NSString).isEqual(to: text) {
                cachedParseGeneration = parseGeneration
                return cachedParsedDocument
            }
        }

        let tokens = parseState.tokens(for: text, edit: edit, registry: cachedExtensionRegistry)
        let tClassify = DispatchTime.now().uptimeNanoseconds
        var codeTokens: [MarkdownToken] = []
        var tableTokens: [MarkdownToken] = []
        var codeBlockTokensWithIndices: [(index: Int, token: MarkdownToken)] = []
        var imageLinkIdx: [(index: Int, token: MarkdownToken)] = []
        var tableIdx: [(index: Int, token: MarkdownToken)] = []

        codeTokens.reserveCapacity(tokens.count / 2)

        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case .codeBlock, .inlineCode:
                codeTokens.append(token)
                if token.kind == .codeBlock {
                    codeBlockTokensWithIndices.append((index, token))
                }
            case .imageLink:
                imageLinkIdx.append((index, token))
            case .table:
                tableTokens.append(token)
                tableIdx.append((index, token))
            default:
                break
            }
        }

        parsedDocumentVersion &+= 1
        let parsed = ParsedDocument(
            tokens: tokens,
            blocks: parseState.currentBlocks,
            codeTokens: codeTokens,
            tableTokens: tableTokens,
            codeBlockTokensWithIndices: codeBlockTokensWithIndices,
            classified: MarkdownStyler.ClassifiedStyleTokens(
                imageLink: imageLinkIdx, table: tableIdx, code: codeTokens),
            version: parsedDocumentVersion
        )
        cachedParsedText = text
        cachedParsedLength = length
        cachedParseGeneration = parseGeneration
        cachedParsedDocument = parsed
        PerfTrace.note {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - tClassify) / 1_000_000
            return "classify=\(String(format: "%.2f", ms))ms #tokens=\(tokens.count)"
        }
        return parsed
    }

    /// Memoized computeActiveTokenIndices — a pure function of
    /// (parsed.version, selection, suppressed) that otherwise runs up to
    /// three times per keystroke on identical inputs (pre-edit ask,
    /// selection change, textDidChange).
    func activeTokenIndices(parsed: ParsedDocument, selection: NSRange, in text: NSString, suppressed: Bool) -> Set<Int> {
        if let memo = activeTokenMemo, memo.version == parsed.version,
           memo.selection == selection, memo.suppressed == suppressed {
            return memo.result
        }
        let result = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: selection, tokens: parsed.tokens, in: text, suppressed: suppressed)
        activeTokenMemo = (parsed.version, selection, suppressed, result)
        return result
    }

    func paragraphRanges(
        in text: NSString,
        intersecting editedRange: NSRange
    ) -> [NSRange] {
        guard text.length > 0 else { return [] }
        guard editedRange.location != NSNotFound else { return [] }

        var start = editedRange.location
        let end = min(NSMaxRange(editedRange), text.length)
        if start >= text.length {
            start = max(0, text.length - 1)
        }
        if end <= start {
            return [text.paragraphRange(for: NSRange(location: start, length: 0))]
        }

        var ranges: [NSRange] = []
        var cursor = start
        while cursor < end {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            ranges.append(paragraph)
            let next = NSMaxRange(paragraph)
            if next <= cursor { break }
            cursor = next
        }
        return ranges
    }

    func tokenRestyleParagraphs(
        in text: NSString,
        tokens: [MarkdownToken],
        currentActiveTokenIndices: Set<Int>,
        previousActiveTokenIndices: Set<Int>
    ) -> [NSRange] {
        var paragraphs: [NSRange] = []
        let indicesToStyle = currentActiveTokenIndices.union(previousActiveTokenIndices)

        for idx in indicesToStyle where idx >= 0 && idx < tokens.count {
            let token = tokens[idx]
            paragraphs.append(text.paragraphRange(for: token.range))

            if token.kind == .codeBlock {
                for markerRange in token.markerRanges {
                    paragraphs.append(text.paragraphRange(for: markerRange))
                }
            }
        }

        return paragraphs
    }

    func restyleParagraphs(_ paragraphs: [NSRange], in textView: NSTextView) {
        let docText = textView.string      // one O(doc) bridge, reused below
        let parsed = parsedDocument(for: docText)
        let tokens = parsed.tokens
        let nsText = docText as NSString
        activeTokenIndices = activeTokenIndices(
            parsed: parsed,
            selection: textView.selectedRange(),
            in: nsText,
            suppressed: !textView.isEditable
        )
        restyleTextView(textView, paragraphCandidates: paragraphs, tokens: tokens,
                        classified: parsed.classified, blocks: parsed.blocks)
    }

}

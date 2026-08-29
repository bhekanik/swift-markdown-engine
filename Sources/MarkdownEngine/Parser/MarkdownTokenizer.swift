//
//  MarkdownTokenizer.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// The token namespace. Tokens are produced by `parseTokensViaAST`
// (`BlockScopedTokenizer`): block structure + block-level tokens come from
// `BlockParser` + `BlockLevelTokenizer` (hand scanners, no regex), inline
// tokens from the AST (`InlineParser` → `InlineASTAdapter`). This file keeps
// only the code-block language helper.
import Foundation

// MARK: - Tokenizer
enum MarkdownTokenizer {

    // MARK: - Code Block Helpers

    static func extractLanguage(from token: MarkdownToken, in text: String) -> String? {
        guard token.kind == .codeBlock,
              let openingMarker = token.markerRanges.first,
              openingMarker.length > 0 else { return nil }

        let nsText = text as NSString
        let fenceCharacter = nsText.character(at: openingMarker.location)
        guard fenceCharacter == 0x60 || fenceCharacter == 0x7E else { return nil }
        var infoStart = openingMarker.location
        let markerEnd = NSMaxRange(openingMarker)
        while infoStart < markerEnd, nsText.character(at: infoStart) == fenceCharacter { infoStart += 1 }
        var infoEnd = markerEnd
        while infoEnd > infoStart {
            let c = nsText.character(at: infoEnd - 1)
            guard c == 0x0A || c == 0x0D else { break }
            infoEnd -= 1
        }
        let langRange = NSRange(location: infoStart, length: infoEnd - infoStart)

        guard langRange.location + langRange.length <= nsText.length else { return nil }

        let langString = nsText.substring(with: langRange).trimmingCharacters(in: .whitespacesAndNewlines)
        return langString.isEmpty ? nil : langString
    }
}

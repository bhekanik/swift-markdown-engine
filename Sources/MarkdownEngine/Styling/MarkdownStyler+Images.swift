//
//  MarkdownStyler+Images.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Markdown image-link styling.
//

import Foundation

extension MarkdownStyler {

    // MARK: Markdown Image Links ![alt](url)

    static func styleImageLinks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (_, token) in ctx.scoped(ctx.imageLinkIndexed) {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
        }
        return attrs
    }
}

//
//  MarkdownFocusBlur.swift
//  MarkdownEngine
//
//  Focus blur: every line but the caret's drawn blurred, more with distance.
//

import CoreGraphics
import CoreImage

/// Where the sharp line is and how the blur grows away from it. Set on
/// ``MarkdownEditorController/focusBlur``; the layout fragments read it as
/// they draw.
public struct MarkdownFocusBlur: Equatable, Sendable {
    /// The caret line's vertical span, in text-container coordinates.
    public var lineMinY: CGFloat
    public var lineMaxY: CGFloat
    /// Blur at full strength, in points.
    public var maximumRadius: CGFloat
    /// Distance, in points, over which the blur ramps from a trace to full.
    public var rampDistance: CGFloat
    /// A band drawn behind the sharp line, the width of the text column, or
    /// `nil` for none.
    public var lineHighlight: CGColor?

    public init(
        lineMinY: CGFloat, lineMaxY: CGFloat, maximumRadius: CGFloat, rampDistance: CGFloat,
        lineHighlight: CGColor? = nil
    ) {
        self.lineMinY = lineMinY
        self.lineMaxY = lineMaxY
        self.maximumRadius = maximumRadius
        self.rampDistance = rampDistance
        self.lineHighlight = lineHighlight
    }

    /// The radius for a line spanning `minY...maxY`. Measured centre to
    /// centre, so the lines touching the caret's (the blank line a caret
    /// often sits on, say) still blur; the caret's own line gets none. Every
    /// other line starts at a third of full strength, so the caret's line
    /// stands alone, and reaches full over `rampDistance`.
    nonisolated public func radius(lineMinY minY: CGFloat, lineMaxY maxY: CGFloat) -> CGFloat {
        let caretMid = (lineMinY + lineMaxY) / 2
        let caretHalf = (lineMaxY - lineMinY) / 2
        let distance = abs((minY + maxY) / 2 - caretMid) - caretHalf
        guard distance > 0.5, rampDistance > 0 else { return 0 }
        let progress = min(1, distance / rampDistance)
        let eased = progress * progress * (3 - 2 * progress)
        let radius = maximumRadius * (0.3 + 0.7 * eased)
        // Quarter-point steps: nearby lines share a radius, so a line's
        // blurred image is reused instead of re-rendered for a hair's change.
        return (radius * 4).rounded() / 4
    }
}

/// Blurred drawing for the layout fragments: draw into a small offscreen
/// bitmap, blur it with Core Image, and draw the result back in place. (Core
/// Graphics has no blur, and its shadow trick draws nothing once the glyphs
/// are moved outside the layer being drawn.)
///
/// Two things keep it off the keystroke's budget: blurred text is rendered
/// at a fraction of the screen's resolution, because a blurred glyph has no
/// detail to lose, and a blurred line is cached by its content and radius, so
/// typing redraws only the lines whose text or distance changed.
enum FocusBlurRenderer {
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])
    nonisolated(unsafe) private static let cache: NSCache<Key, CGImage> = {
        let cache = NSCache<Key, CGImage>()
        cache.countLimit = 400
        return cache
    }()

    /// What a cached image depends on: the content, the radius, the size.
    nonisolated final class Key: NSObject {
        let content: NSAttributedString
        let radius: CGFloat
        let size: CGSize

        nonisolated init(content: NSAttributedString, radius: CGFloat, size: CGSize) {
            self.content = content
            self.radius = radius
            self.size = size
        }

        nonisolated override var hash: Int {
            var hasher = Hasher()
            hasher.combine(content.string)
            hasher.combine(radius)
            hasher.combine(size.width)
            hasher.combine(size.height)
            return hasher.finalize()
        }

        nonisolated override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return radius == other.radius && size == other.size && content.isEqual(to: other.content)
        }
    }

    /// Draw what `body` draws inside `rect` (in `context`'s user space),
    /// blurred by `radius` points. With a `cacheKey` the blurred image is
    /// kept and reused while the key's content and radius stay the same.
    nonisolated static func draw(
        in rect: CGRect, radius: CGFloat, context: CGContext, cacheKey: NSAttributedString? = nil,
        _ body: (CGContext) -> Void
    ) {
        let pad = ceil(radius * 3)
        let area = rect.insetBy(dx: -pad, dy: -pad)
        let key = cacheKey.map { Key(content: $0, radius: radius, size: rect.size) }
        let image = key.flatMap { cache.object(forKey: $0) } ?? render(area: area, radius: radius, context: context, body)
        guard let image else { return }
        if let key { cache.setObject(image, forKey: key) }
        context.saveGState()
        // Undo the flip for the image, whose rows run bottom-up; smooth
        // scaling back up from the reduced resolution.
        context.interpolationQuality = .medium
        context.translateBy(x: area.minX, y: area.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: area.size))
        context.restoreGState()
    }

    nonisolated private static func render(
        area: CGRect, radius: CGFloat, context: CGContext, _ body: (CGContext) -> Void
    ) -> CGImage? {
        let screenScale = max(abs(context.userSpaceToDeviceSpaceTransform.a), 1)
        // The more blur, the less resolution it needs: full at a trace of
        // blur, down to half a point per pixel at full strength.
        let scale = max(0.5, min(screenScale, screenScale * 2 / (2 + radius)))
        let width = Int(ceil(area.width * scale)), height = Int(ceil(area.height * scale))
        guard width > 0, height > 0,
              let bitmap = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        // The fragment context is flipped (y down), the bitmap is not.
        bitmap.scaleBy(x: scale, y: -scale)
        bitmap.translateBy(x: -area.minX, y: -area.maxY)
        body(bitmap)
        guard let image = bitmap.makeImage() else { return nil }
        let blurred = CIImage(cgImage: image)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius * scale / 2))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return Self.context.createCGImage(blurred, from: blurred.extent)
    }
}

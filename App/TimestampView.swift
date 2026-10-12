import AppKit
import CoreText

struct TimestampArtwork {
    let line: CTLine
    let inkBounds: CGRect

    static func make(_ timestamp: String, width: CGFloat, height: CGFloat, color: NSColor = .white) -> TimestampArtwork {
        func line(at size: CGFloat) -> CTLine {
            let font = CTFontCreateWithName("ISO8601Kawara-Regular" as CFString, size, nil)
            let result = NSAttributedString(string: timestamp, attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: -0.052 * size
            ])
            return CTLineCreateWithAttributedString(result)
        }
        let reference = line(at: 100)
        let referenceBounds = CTLineGetBoundsWithOptions(reference, .useGlyphPathBounds)
        // Invisible input (for example, zero-width characters) has no ink to fit.
        let widthScale = referenceBounds.width > 0 ? width / referenceBounds.width : .infinity
        let heightScale = referenceBounds.height > 0 ? height / referenceBounds.height : .infinity
        let scale = min(widthScale, heightScale)
        let fitted = line(at: scale.isFinite ? 100 * scale : 100)
        return TimestampArtwork(line: fitted, inkBounds: CTLineGetBoundsWithOptions(fitted, .useGlyphPathBounds))
    }
}

final class TimestampView: NSView {
    var artwork: TimestampArtwork? {
        didSet { needsDisplay = true }
    }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let artwork, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(dirtyRect)
        context.setBlendMode(.normal)
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: (bounds.width - artwork.inkBounds.width) / 2 - artwork.inkBounds.minX,
            y: (bounds.height - artwork.inkBounds.height) / 2 - artwork.inkBounds.minY
        )
        CTLineDraw(artwork.line, context)
        context.restoreGState()
    }
}

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

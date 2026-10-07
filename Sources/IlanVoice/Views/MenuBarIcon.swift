import AppKit

/// The menu bar glyph: the app icon's portrait (head, ears, shoulders and the
/// open-collar tee) as a single-colour template image, so macOS tints it for
/// light and dark menu bars like every other status item. Drawn in the icon's
/// own 512-unit coordinates (see Resources/icon.svg) with the face features
/// punched out, and thickened so they still read at 18 pt.
enum MenuBarIcon {
    static let image: NSImage = make(size: 18)

    static func make(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            // The figure spans x 24…488, y 52…512 in icon units.
            let scale = rect.height / 470
            cg.translateBy(x: (rect.width - 464 * scale) / 2 - 24 * scale, y: -46 * scale)
            cg.scaleBy(x: scale, y: scale)

            cg.setFillColor(NSColor.black.cgColor)
            // Head: wide crown tapering to the chin.
            let head = CGMutablePath()
            head.move(to: CGPoint(x: 256, y: 64))
            head.addCurve(to: CGPoint(x: 404, y: 222), control1: CGPoint(x: 340, y: 64), control2: CGPoint(x: 404, y: 140))
            head.addCurve(to: CGPoint(x: 256, y: 392), control1: CGPoint(x: 404, y: 320), control2: CGPoint(x: 338, y: 392))
            head.addCurve(to: CGPoint(x: 108, y: 222), control1: CGPoint(x: 174, y: 392), control2: CGPoint(x: 108, y: 320))
            head.addCurve(to: CGPoint(x: 256, y: 64), control1: CGPoint(x: 108, y: 140), control2: CGPoint(x: 172, y: 64))
            head.closeSubpath()
            cg.addPath(head)
            cg.fillPath()
            // Ears.
            cg.fillEllipse(in: CGRect(x: 80, y: 200, width: 48, height: 76))
            cg.fillEllipse(in: CGRect(x: 384, y: 200, width: 48, height: 76))
            // Shoulders, separated from the chin by a clear gap.
            let shoulders = CGMutablePath()
            shoulders.move(to: CGPoint(x: 24, y: 512))
            shoulders.addCurve(to: CGPoint(x: 256, y: 428), control1: CGPoint(x: 24, y: 458), control2: CGPoint(x: 120, y: 428))
            shoulders.addCurve(to: CGPoint(x: 488, y: 512), control1: CGPoint(x: 392, y: 428), control2: CGPoint(x: 488, y: 458))
            shoulders.closeSubpath()
            cg.addPath(shoulders)
            cg.fillPath()

            // Punch out the face and the open collar.
            cg.setBlendMode(.clear)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.fillEllipse(in: CGRect(x: 184, y: 218, width: 46, height: 46))   // eyes
            cg.fillEllipse(in: CGRect(x: 282, y: 218, width: 46, height: 46))
            cg.setLineWidth(30)                                                  // brows
            cg.move(to: CGPoint(x: 168, y: 190))
            cg.addQuadCurve(to: CGPoint(x: 238, y: 178), control: CGPoint(x: 202, y: 166))
            cg.move(to: CGPoint(x: 274, y: 178))
            cg.addQuadCurve(to: CGPoint(x: 344, y: 190), control: CGPoint(x: 310, y: 166))
            cg.strokePath()
            cg.setLineWidth(34)                                                  // smile
            cg.move(to: CGPoint(x: 196, y: 300))
            cg.addQuadCurve(to: CGPoint(x: 316, y: 300), control: CGPoint(x: 256, y: 356))
            cg.strokePath()
            let collar = CGMutablePath()                                         // V-neck
            collar.move(to: CGPoint(x: 206, y: 424))
            collar.addLine(to: CGPoint(x: 256, y: 512))
            collar.addLine(to: CGPoint(x: 306, y: 424))
            collar.closeSubpath()
            cg.addPath(collar)
            cg.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ilan Voice"
        return image
    }
}

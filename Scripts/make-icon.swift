import AppKit

// Draws the app icon and writes an .iconset, which `iconutil` then packs.
// Generated rather than shipped as a binary so the icon stays reviewable in the
// repo and can be re-tinted without an image editor.

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    // macOS icons occupy ~80% of the canvas with a drop shadow.
    let inset = size * 0.098
    let plate = rect.insetBy(dx: inset, dy: inset)
    let radius = plate.width * 0.2237 // Apple's squircle ratio

    let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [
        CGColor(red: 0.13, green: 0.16, blue: 0.24, alpha: 1),
        CGColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: plate.midX, y: plate.maxY),
                               end: CGPoint(x: plate.midX, y: plate.minY),
                               options: [])
    context.restoreGState()

    // Two overlapping display outlines: "display++" is about more than one screen.
    context.saveGState()
    context.setStrokeColor(CGColor(red: 0.42, green: 0.65, blue: 1.0, alpha: 1))
    context.setLineWidth(size * 0.035)
    context.setLineJoin(.round)

    let back = CGRect(x: plate.minX + plate.width * 0.24, y: plate.minY + plate.height * 0.40,
                      width: plate.width * 0.44, height: plate.height * 0.30)
    context.addPath(CGPath(roundedRect: back, cornerWidth: size * 0.03, cornerHeight: size * 0.03, transform: nil))
    context.strokePath()

    let front = CGRect(x: plate.minX + plate.width * 0.34, y: plate.minY + plate.height * 0.26,
                       width: plate.width * 0.44, height: plate.height * 0.30)
    context.setFillColor(CGColor(red: 0.09, green: 0.11, blue: 0.18, alpha: 1))
    context.addPath(CGPath(roundedRect: front, cornerWidth: size * 0.03, cornerHeight: size * 0.03, transform: nil))
    context.fillPath()

    context.setStrokeColor(CGColor(red: 0.72, green: 0.85, blue: 1.0, alpha: 1))
    context.addPath(CGPath(roundedRect: front, cornerWidth: size * 0.03, cornerHeight: size * 0.03, transform: nil))
    context.strokePath()

    // Brightness ramp inside the front screen: the app's core control.
    let barCount = 7
    let barArea = front.insetBy(dx: front.width * 0.12, dy: front.height * 0.26)
    let gap = barArea.width * 0.06
    let barWidth = (barArea.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
    for index in 0..<barCount {
        let fraction = CGFloat(index + 1) / CGFloat(barCount)
        let x = barArea.minX + CGFloat(index) * (barWidth + gap)
        let height = barArea.height * fraction
        let barRect = CGRect(x: x, y: barArea.minY, width: barWidth, height: height)
        context.setFillColor(CGColor(red: 0.42, green: 0.65, blue: 1.0, alpha: 0.55 + 0.45 * fraction))
        context.addPath(CGPath(roundedRect: barRect, cornerWidth: barWidth * 0.4, cornerHeight: barWidth * 0.4, transform: nil))
        context.fillPath()
    }
    context.restoreGState()

    image.unlockFocus()
    return image
}

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, size) in variants {
    let image = draw(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
}

print("wrote \(outputDir)")

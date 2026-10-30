// Renders MeshBar's app icon with CoreGraphics so it is reproducible.
// Usage: swift scripts/make-icon.swift <output.iconset>
// scripts/make-icon.sh turns the iconset into Resources/AppIcon.icns.
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Draws on a 1024 x 1024 canvas, following Apple's macOS icon grid:
/// an 824 pt rounded square centred with room for the drop shadow.
func draw(in ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0.06, 0.30, 0.72))
    ctx.fillPath()
    ctx.restoreGState()

    // Tile: blue to teal gradient, top lighter, like Apple's system icons.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0.33, 0.78, 1.0), color(0.10, 0.47, 0.96), color(0.05, 0.26, 0.70)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Faint Wi-Fi arcs behind the mesh.
    let origin = CGPoint(x: 512, y: 250)
    ctx.setLineCap(.round)
    for (index, radius) in [190.0, 330.0, 470.0].enumerated() {
        ctx.setStrokeColor(color(1, 1, 1, 0.16 - CGFloat(index) * 0.035))
        ctx.setLineWidth(58)
        ctx.addArc(center: origin, radius: radius, startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: false)
        ctx.strokePath()
    }

    // Mesh: four nodes, every one linked to the router in the middle.
    let router = CGPoint(x: 512, y: 470)
    let nodes = [CGPoint(x: 512, y: 735), CGPoint(x: 285, y: 330), CGPoint(x: 739, y: 330)]
    ctx.setStrokeColor(color(1, 1, 1, 0.45))
    ctx.setLineWidth(16)
    for (a, b) in [(0, 1), (1, 2), (2, 0)] {
        ctx.move(to: nodes[a]); ctx.addLine(to: nodes[b])
    }
    ctx.strokePath()
    ctx.setStrokeColor(color(1, 1, 1, 0.9))
    ctx.setLineWidth(22)
    for node in nodes {
        ctx.move(to: router); ctx.addLine(to: node)
    }
    ctx.strokePath()

    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0, 0.1, 0.35, 0.45))
    ctx.setFillColor(color(1, 1, 1))
    for node in nodes {
        ctx.fillEllipse(in: CGRect(x: node.x - 62, y: node.y - 62, width: 124, height: 124))
    }
    ctx.fillEllipse(in: CGRect(x: router.x - 86, y: router.y - 86, width: 172, height: 172))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(color(0.10, 0.47, 0.96))
    ctx.fillEllipse(in: CGRect(x: router.x - 34, y: router.y - 34, width: 68, height: 68))

    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(1, 1, 1, 0.18))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func render(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    draw(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: URL(fileURLWithPath: "\(output)/\(name)"))
    }
}
print("Wrote \(output)")

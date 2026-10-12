// P02-011: generate the original sPDF Editor development icon (a page with
// text lines and a redaction bar) as a 1024px master PNG. Run with:
//   swift Tools/IconGenerator/make-icon.swift <output-png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
  fputs("usage: make-icon.swift <output-png>\n", stderr)
  exit(2)
}

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard
  let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }
context.clear(CGRect(x: 0, y: 0, width: size, height: size))

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
  CGColor(red: r, green: g, blue: b, alpha: a)
}

let page = CGRect(x: 232, y: 92, width: 560, height: 840)
let radius: CGFloat = 64
// Page body.
let pagePath = CGPath(
  roundedRect: page, cornerWidth: radius, cornerHeight: radius, transform: nil)
context.setFillColor(color(0.96, 0.97, 0.99))
context.addPath(pagePath)
context.fillPath()
// Page edge.
context.setStrokeColor(color(0.62, 0.66, 0.72))
context.setLineWidth(10)
context.addPath(pagePath)
context.strokePath()
// Folded corner (accent).
let fold = CGMutablePath()
fold.move(to: CGPoint(x: page.maxX - 200, y: page.maxY))
fold.addLine(to: CGPoint(x: page.maxX, y: page.maxY))
fold.addLine(to: CGPoint(x: page.maxX, y: page.maxY - 200))
fold.closeSubpath()
context.setFillColor(color(0.10, 0.47, 0.96))
context.addPath(fold)
context.fillPath()
// Text lines.
context.setFillColor(color(0.23, 0.27, 0.33))
for (index, width) in [420.0, 460.0, 380.0].enumerated() {
  let y = CGFloat(700 - index * 110)
  context.fill(CGRect(x: 292, y: y, width: CGFloat(width), height: 44))
}
// Redaction bar (the product mark).
context.setFillColor(color(0.08, 0.09, 0.11))
context.fill(CGRect(x: 292, y: 340, width: 440, height: 72))
// Accent underline.
context.setFillColor(color(0.10, 0.47, 0.96))
context.fill(CGRect(x: 292, y: 210, width: 220, height: 36))

guard let image = context.makeImage() else { exit(1) }
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
guard
  let destination = CGImageDestinationCreateWithURL(
    url, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
  fputs("encoding failed\n", stderr)
  exit(1)
}

// Draws the CallRecorder 1024×1024 icon: a glassy squircle, a two-voice conversation waveform
// (them on top in light blue, you below in mint, as in the player) and a red recording dot.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit
import CoreGraphics

let size = 1024.0
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A continuous-curvature superellipse like macOS icons (824 pt body on the 1024 grid).
func squircle(in rect: CGRect, exponent: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for step in 0...720 {
        let t = Double(step) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / exponent), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / exponent), s)
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = squircle(in: body)

// Drop shadow.
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
context.addPath(shape)
context.setFillColor(color(0x101533))
context.fillPath()
context.restoreGState()

// Background: deep indigo → teal.
context.saveGState()
context.addPath(shape)
context.clip()
let background = CGGradient(colorsSpace: space, colors: [color(0x2B2F86), color(0x173C7A), color(0x0B6A78)] as CFArray,
                            locations: [0, 0.55, 1])!
context.drawLinearGradient(background, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

// Soft glow behind the waveform.
let glow = CGGradient(colorsSpace: space, colors: [color(0x6FD3FF, 0.35), color(0x6FD3FF, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 500), endRadius: 360, options: [])

// Waveform: them on top, you below; bars with rounded caps.
let remoteHeights: [CGFloat] = [0.20, 0.42, 0.68, 0.95, 0.74, 0.52, 0.86, 0.60, 0.34, 0.18, 0.10]
let localHeights: [CGFloat] = [0.10, 0.22, 0.30, 0.48, 0.70, 0.92, 0.62, 0.80, 0.50, 0.28, 0.14]
let barWidth: CGFloat = 38, gap: CGFloat = 20, centerY: CGFloat = 500, halfGap: CGFloat = 9, maxHeight: CGFloat = 250
let totalWidth = CGFloat(remoteHeights.count) * barWidth + CGFloat(remoteHeights.count - 1) * gap
let startX = 512 - totalWidth / 2
for (index, (up, down)) in zip(remoteHeights, localHeights).enumerated() {
    let x = startX + CGFloat(index) * (barWidth + gap)
    let top = CGRect(x: x, y: centerY + halfGap, width: barWidth, height: max(barWidth, up * maxHeight))
    let bottom = CGRect(x: x, y: centerY - halfGap - max(barWidth, down * maxHeight), width: barWidth, height: max(barWidth, down * maxHeight))
    context.addPath(CGPath(roundedRect: top, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    context.setFillColor(color(0x8AD4FF))
    context.fillPath()
    context.addPath(CGPath(roundedRect: bottom, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    context.setFillColor(color(0x5FE3A8))
    context.fillPath()
}

// Red recording dot with a glow.
let dot = CGPoint(x: 742, y: 778)
let dotGlow = CGGradient(colorsSpace: space, colors: [color(0xFF3B30, 0.55), color(0xFF3B30, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(dotGlow, startCenter: dot, startRadius: 0, endCenter: dot, endRadius: 120, options: [])
context.addEllipse(in: CGRect(x: dot.x - 54, y: dot.y - 54, width: 108, height: 108))
context.setFillColor(color(0xFF453A))
context.fillPath()
context.addEllipse(in: CGRect(x: dot.x - 30, y: dot.y + 8, width: 40, height: 26))
context.setFillColor(color(0xFFFFFF, 0.35))
context.fillPath()

// Glass highlight at the top.
let highlight = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(highlight, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.midY + 40), options: [])
context.restoreGState()

// Thin light rim.
context.addPath(shape)
context.setStrokeColor(color(0xFFFFFF, 0.28))
context.setLineWidth(3)
context.strokePath()

let image = context.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: output))
print("icon: \(output)")

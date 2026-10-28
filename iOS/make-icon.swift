// Renders the BensVoice app icon: swift make-icon.swift BensVoice/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ h: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

// Background: deep ink, lighter toward the top left
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x272C3A), rgb(0x12141B)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Soft warm glow behind the waveform
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFF5A36, 0.30), rgb(0xFF5A36, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
                       endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: 430, options: [])

// Waveform: seven rounded bars, symmetric
let heights: [CGFloat] = [0.16, 0.34, 0.56, 0.74, 0.56, 0.34, 0.16]
let barWidth: CGFloat = 70, gap: CGFloat = 42
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (size - total) / 2
let bars = CGMutablePath()
for h in heights {
    let height = h * size
    bars.addPath(CGPath(roundedRect: CGRect(x: x, y: (size - height) / 2, width: barWidth, height: height),
                        cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    x += barWidth + gap
}
ctx.saveGState()
ctx.addPath(bars)
ctx.clip()
let warm = CGGradient(colorsSpace: space, colors: [rgb(0xFFB347), rgb(0xFF4D3D)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(warm, start: CGPoint(x: 0, y: size * 0.87), end: CGPoint(x: 0, y: size * 0.13), options: [])
ctx.restoreGState()

NSGraphicsContext.current = nil
// App icons can't have an alpha channel, so flatten onto an opaque bitmap.
let flat = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
flat.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: size, height: size))
try! NSBitmapImageRep(cgImage: flat.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

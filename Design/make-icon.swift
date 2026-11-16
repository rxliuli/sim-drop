// Usage: swift Design/make-icon.swift Design/icon-source.png SimDrop/Assets.xcassets/AppIcon.appiconset
// Takes a full-bleed squircle image, scales it to
// macOS icon geometry (824pt body on a 1024 canvas, soft shadow) and writes all sizes.
import AppKit

let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// 1. The source is already a full-bleed squircle (transparent corners); use it as-is.
let body = src

// 2. Render a 1024 master: 824 body, continuous-corner mask, drop shadow.
func render(_ size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high
    let rect = CGRect(x: 100 * s, y: 100 * s + 10 * s, width: 824 * s, height: 824 * s)
    // The source already has its own squircle alpha; draw it with a drop shadow.
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.draw(body, in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try render(pt * scale).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
try render(1024).write(to: URL(fileURLWithPath: "Design/icon-1024.png"))
print("done")

// make-icons.swift — regenerate the app's image resources from the artwork in design/.
//
//   swift scripts/make-icons.swift
//
//   design/app-icon.png          ->  Resources/goblin.icns, goblin-avatar.png
//   design/menu-bar-glyph.png    ->  Resources/goblin-bar.png   (trimmed to its bounds)
//   design/mascot/*.png          ->  Resources/mascot-<name>.png (downsized)
//
// Only AppKit is needed, so this runs on any Mac with the Xcode command line tools.
// Commit the outputs: the app build does not run this.

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let design = root.appendingPathComponent("design")
let out = root.appendingPathComponent("Sources/Goblin/Resources")

func load(_ path: String) -> NSImage {
    guard let image = NSImage(contentsOf: design.appendingPathComponent(path)) else {
        FileHandle.standardError.write(Data("cannot read design/\(path)\n".utf8)); exit(1)
    }
    return image
}

func bitmap(_ pixels: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)!
}

func png(_ image: NSImage, pixels: Int, from source: NSRect? = nil) -> Data {
    let rep = bitmap(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: source ?? .zero,
               operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// --- app icon ---------------------------------------------------------------
let app = load("app-icon.png")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(app, pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(app, pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("goblin.icns").path]
try iconutil.run(); iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { print("iconutil failed"); exit(1) }

// the popover header shows the icon at 76pt, so 2x of that plus a little
try png(app, pixels: 256).write(to: out.appendingPathComponent("goblin-avatar.png"))

// --- menu bar glyph: trimmed so the goblin fills the 15pt box it is drawn into ---
let glyph = load("menu-bar-glyph.png")
guard let cg = glyph.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("no glyph"); exit(1) }
let w = cg.width, h = cg.height
let probe = NSBitmapImageRep(cgImage: cg)
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w where (probe.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
let side = CGFloat(max(maxX - minX, maxY - minY) + 1)
// square crop centred on the bounds, in AppKit's bottom-left coordinates
let cx = CGFloat(minX + maxX) / 2, cy = CGFloat(h) - CGFloat(minY + maxY) / 2
let crop = NSRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
try png(glyph, pixels: 108, from: crop).write(to: out.appendingPathComponent("goblin-bar.png"))

// --- mascot illustrations ------------------------------------------------------
let mascotDir = design.appendingPathComponent("mascot")
for file in try FileManager.default.contentsOfDirectory(atPath: mascotDir.path) where file.hasSuffix(".png") {
    let name = (file as NSString).deletingPathExtension
    try png(load("mascot/\(file)"), pixels: 384).write(to: out.appendingPathComponent("mascot-\(name).png"))
}

print("wrote goblin.icns, goblin-avatar.png, goblin-bar.png, mascot-*.png")

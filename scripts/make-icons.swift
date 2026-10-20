// make-icons.swift — regenerate every icon asset from the two SVGs in design/.
//
//   swift scripts/make-icons.swift
//
//   design/goblin-app.svg  ->  Resources/goblin.icns, goblin-avatar.png
//   design/goblin-bar.svg  ->  Resources/goblin-bar.pdf   (vector, tinted by macOS)
//
// CoreSVG (what NSImage uses to read SVG) is the only dependency, so this runs on any
// Mac with the Xcode command line tools. Commit the outputs: the app build does not
// run this.

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let design = root.appendingPathComponent("design")
let out = root.appendingPathComponent("Sources/Goblin/Resources")

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: design.appendingPathComponent(name)) else {
        FileHandle.standardError.write(Data("cannot read design/\(name)\n".utf8)); exit(1)
    }
    return image
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// --- app icon ---------------------------------------------------------------
let app = load("goblin-app.svg")
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

// the popover header shows the icon at 40pt, so 2x of that with room to spare
try png(app, pixels: 256).write(to: out.appendingPathComponent("goblin-avatar.png"))

// --- menu bar glyph: vector PDF ---------------------------------------------
let bar = load("goblin-bar.svg")
var box = CGRect(x: 0, y: 0, width: 64, height: 64)
let pdfData = NSMutableData()
let consumer = CGDataConsumer(data: pdfData)!
let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
ctx.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
bar.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
NSGraphicsContext.restoreGraphicsState()
ctx.endPDFPage(); ctx.closePDF()
try pdfData.write(to: out.appendingPathComponent("goblin-bar.pdf"))

print("wrote goblin.icns, goblin-avatar.png, goblin-bar.pdf")

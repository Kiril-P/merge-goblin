import AppKit
for (name, pt) in [("wifi", 15.0), ("battery.100percent", 17.0), ("magnifyingglass", 14.0), ("switch.2", 14.0), ("apple.logo", 16.0)] {
  let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .medium)
  guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { print("no", name); continue }
  let s = img.size; let scale: CGFloat = 4
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s.width*scale), pixelsHigh: Int(s.height*scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = s
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  img.draw(in: NSRect(origin: .zero, size: s)); NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "ui/sym-\(name).png"))
  print(name, s)
}

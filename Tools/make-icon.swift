import AppKit

// Uygulama simgesi: koyu lacivert-mor zemin, ortada baş silüeti, sağ yarı
// "cam" gibi açık ve bulanık. Fikri anlatıyor: kafanın döndüğü tarafta
// ekranın bir bölümü camın arkasında kalıyor.
func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = size
    let rect = NSRect(x: 0, y: 0, width: s, height: s)

    // macOS simge yuvarlatması (~%22)
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.05, dy: s * 0.05), xRadius: s * 0.2, yRadius: s * 0.2)
    path.addClip()

    let bg = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.32, green: 0.17, blue: 0.48, alpha: 1),
    ])!
    bg.draw(in: rect, angle: -60)

    // Baş silüeti (daire + boyun)
    let head = NSBezierPath()
    head.appendOval(in: NSRect(x: s * 0.31, y: s * 0.40, width: s * 0.38, height: s * 0.38))
    let neck = NSBezierPath(roundedRect: NSRect(x: s * 0.24, y: s * 0.14, width: s * 0.52, height: s * 0.26), xRadius: s * 0.13, yRadius: s * 0.13)
    head.append(neck)
    NSColor(calibratedWhite: 0.97, alpha: 0.95).setFill()
    head.fill()

    // Sağ yarı: cam katmanı. Açık, yarı saydam, kenarda parlak çizgi.
    let glassRect = NSRect(x: s * 0.52, y: 0, width: s * 0.48, height: s)
    let glass = NSGradient(colors: [
        NSColor(calibratedWhite: 1, alpha: 0.55),
        NSColor(calibratedWhite: 1, alpha: 0.30),
    ])!
    glass.draw(in: glassRect, angle: 0)
    // Yumuşak kenar: şeridin başında ince bir ışık
    let edge = NSGradient(colors: [
        NSColor(calibratedWhite: 1, alpha: 0.0),
        NSColor(calibratedWhite: 1, alpha: 0.9),
        NSColor(calibratedWhite: 1, alpha: 0.0),
    ])!
    edge.draw(in: NSRect(x: s * 0.50, y: 0, width: s * 0.04, height: s), angle: 0)

    // Camın arkasındaki baş parçası daha soluk (bulanık izlenimi)
    NSColor(calibratedWhite: 1, alpha: 0.35).setFill()
    let cover = NSBezierPath(rect: glassRect)
    cover.append(head)
    cover.windingRule = .evenOdd
    // Yalnızca cam içinde kalan baş kısmını hafifçe yumuşat: üstüne aynı
    // renkten yarı saydam bir katman.
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(rect: glassRect).addClip()
    NSColor(calibratedRed: 0.55, green: 0.45, blue: 0.75, alpha: 0.35).setFill()
    head.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    image.unlockFocus()
    return image
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let img = draw(size: CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name).png"))
}
print("png hazır")

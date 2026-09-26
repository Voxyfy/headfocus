import AppKit

/// Menü çubuğu simgesi: baş silüeti, sağ yarısı çizgili (cam). SF'nin
/// kulaklık simgesi 18 pikselde mikrofona benziyordu. Şablon görsel:
/// sistem açık/koyu menü çubuğuna göre kendisi renklendiriyor.
enum StatusIcon {
    static func make(paused: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            // Baş
            let head = NSBezierPath(ovalIn: NSRect(x: 5.5, y: 8.5, width: 7, height: 7))
            head.fill()
            // Omuzlar
            let body = NSBezierPath(roundedRect: NSRect(x: 3, y: 2, width: 12, height: 6), xRadius: 3, yRadius: 3)
            body.fill()
            // Sağ yarıda "cam": ince dikey çizgiler
            NSColor.black.withAlphaComponent(0.55).setFill()
            for x in stride(from: 13.5, through: 16.5, by: 1.5) {
                NSRect(x: x, y: 2, width: 0.8, height: 14).fill()
            }
            if paused {
                NSColor.black.setFill()
                NSRect(x: 1, y: 12, width: 1.6, height: 5).fill()
                NSRect(x: 3.4, y: 12, width: 1.6, height: 5).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

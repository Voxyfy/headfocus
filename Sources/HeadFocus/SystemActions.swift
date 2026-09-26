import AppKit
import ApplicationServices
import Foundation

/// Sistemle konuşan parçalar: ses, Rahatsız Etmeyin, erişilebilirlik izni,
/// kaydırma / masaüstü / imleç olayları.
enum SystemActions {
    // MARK: Ses

    private static var mutedByUs = false

    static func muteOutput() {
        guard !mutedByUs else { return }
        if let muted = run("output muted of (get volume settings)"), muted == "true" { return }
        _ = run("set volume output muted true")
        mutedByUs = true
    }

    static func restoreOutput() {
        guard mutedByUs else { return }
        _ = run("set volume output muted false")
        mutedByUs = false
    }

    // MARK: Rahatsız Etmeyin
    //
    // macOS'ta odak modunu açan açık bir API yok. Kısayollar uygulamasında
    // kullanıcının oluşturduğu iki kısayol çalıştırılıyor: "HeadFocus Odak Aç"
    // (Odak Ayarla → Rahatsız Etmeyin, açık) ve "HeadFocus Odak Kapat".
    // Kısayol yoksa sessizce geçilir; README anlatıyor.

    static func setDoNotDisturb(_ on: Bool) {
        let name = on ? "HeadFocus Odak Aç" : "HeadFocus Odak Kapat"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: Erişilebilirlik

    /// Kaydırma, masaüstü geçişi ve imleç için sistem olayı göndermek
    /// Erişilebilirlik izni ister. İlk çağrıda sistem istemi çıkar.
    @discardableResult
    static func ensureAccessibility(prompt: Bool = true) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    // MARK: Olaylar

    static func scroll(pixels: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    /// Ctrl+← / Ctrl+→ : sistemin masaüstü geçişi kısayolu.
    static func switchSpace(right: Bool) {
        let key: CGKeyCode = right ? 124 : 123
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return }
        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func moveMouse(to point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    static func click(at point: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: Yardımcı

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return result?.stringValue
    }
}

import AppKit
import CoreMotion
import UserNotifications

/// Menü çubuğu uygulaması. Dock'ta görünmez (LSUIElement).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let tracker = HeadTracker()
    private let overlay = OverlayController()
    private let session = FocusSession()

    // Ayarlar (UserDefaults'ta kalıcı)
    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enabled"); refreshMenu() }
    }
    /// Yan blur'un başladığı açı (derece) ve tamamen dolduğu açı.
    private var startAngle: Double {
        get { UserDefaults.standard.object(forKey: "startAngle") as? Double ?? 12 }
        set { UserDefaults.standard.set(newValue, forKey: "startAngle"); refreshMenu() }
    }
    private let fullAngle: Double = 45
    /// Odak modunda "ekrandan uzaklaştı" eşiği.
    private let awayAngle: Double = 35

    private var connected = false
    private var lastPose = HeadTracker.Pose(yaw: 0, pitch: 0)

    private var menu = NSMenu()
    private var statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var sessionLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "HeadFocus")
        statusItem.menu = menu
        buildMenu()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        tracker.onAvailabilityChange = { [weak self] available in
            self?.connected = available
            if !available { self?.overlay.clear() }
            self?.refreshMenu()
        }
        tracker.onPose = { [weak self] pose in self?.handle(pose) }
        session.onChange = { [weak self] in self?.sessionChanged() }

        connected = tracker.isAvailable
        tracker.start()
        refreshMenu()
    }

    // MARK: Kafa verisi

    private func handle(_ pose: HeadTracker.Pose) {
        lastPose = pose
        if !connected { connected = true; refreshMenu() }

        let away = abs(pose.yaw) >= awayAngle || pose.pitch <= -awayAngle
        session.update(away: away)

        if session.state == .paused {
            overlay.showFull(message: "Ekrana dön · \(session.remainingLabel) duraklatıldı")
            return
        }

        guard enabled else { overlay.clear(); return }

        let magnitude = abs(pose.yaw)
        if magnitude < startAngle {
            overlay.showSide(fraction: 0, side: 0)
            return
        }
        // Başlangıç açısında ince şerit, tam açıda ekranın yarısı.
        let t = min(1, (magnitude - startAngle) / (fullAngle - startAngle))
        let fraction = 0.08 + 0.42 * t
        // Sağa dönüş (yaw negatif) → sağ taraf bulanır. Kullanıcının istediği
        // davranış bu; tersini isteyen ayarı değiştirir (yakında).
        overlay.showSide(fraction: fraction, side: pose.yaw < 0 ? -1 : 1)
    }

    private func sessionChanged() {
        switch session.state {
        case .finished:
            overlay.clear()
            statusItem.button?.title = ""
        case .idle:
            overlay.clear()
            statusItem.button?.title = ""
        case .running:
            statusItem.button?.title = " " + session.remainingLabel
        case .paused:
            statusItem.button?.title = " ⏸ " + session.remainingLabel
        }
        refreshMenu()
    }

    // MARK: Menü

    private func buildMenu() {
        menu.removeAllItems()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Yan bulanıklık", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.tag = 1
        menu.addItem(toggle)

        let recal = NSMenuItem(title: "Düz bakışı sıfırla", action: #selector(recalibrate), keyEquivalent: "r")
        recal.target = self
        menu.addItem(recal)

        let sens = NSMenu(title: "Hassasiyet")
        for (title, angle) in [("Yüksek (8°)", 8.0), ("Normal (12°)", 12.0), ("Düşük (20°)", 20.0)] {
            let item = NSMenuItem(title: title, action: #selector(setSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = angle
            sens.addItem(item)
        }
        let sensItem = NSMenuItem(title: "Hassasiyet", action: nil, keyEquivalent: "")
        sensItem.submenu = sens
        sensItem.tag = 2
        menu.addItem(sensItem)

        menu.addItem(.separator())
        sessionLine.isEnabled = false
        menu.addItem(sessionLine)
        for minutes in [15, 25, 50] {
            let item = NSMenuItem(title: "Odak modu · \(minutes) dk", action: #selector(startFocus(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            item.tag = 3
            menu.addItem(item)
        }
        let stopItem = NSMenuItem(title: "Odak modunu bitir", action: #selector(stopFocus), keyEquivalent: "")
        stopItem.target = self
        stopItem.tag = 4
        menu.addItem(stopItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        refreshMenu()
    }

    private func refreshMenu() {
        let auth = tracker.authorization
        if auth == .denied || auth == .restricted {
            statusLine.title = "Hareket izni yok · Sistem Ayarları → Gizlilik → Hareket ve Fitness"
        } else if !tracker.isAvailable {
            statusLine.title = "Destekleyen kulaklık yok"
        } else if !connected {
            statusLine.title = "AirPods bekleniyor"
        } else {
            statusLine.title = String(format: "Bağlı · yön %+.0f° · eğim %+.0f°", lastPose.yaw, lastPose.pitch)
        }

        menu.item(withTag: 1)?.state = enabled ? .on : .off
        if let sens = menu.item(withTag: 2)?.submenu {
            for item in sens.items {
                item.state = (item.representedObject as? Double) == startAngle ? .on : .off
            }
        }

        let running = session.state == .running || session.state == .paused
        sessionLine.title = switch session.state {
        case .idle: "Odak modu kapalı"
        case .running: "Odak · kalan \(session.remainingLabel)"
        case .paused: "Odak duraklatıldı · ekrana dön"
        case .finished: "Odak süresi tamamlandı"
        }
        for item in menu.items where item.tag == 3 { item.isHidden = running }
        menu.item(withTag: 4)?.isHidden = !running
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        if !enabled { overlay.clear() }
    }

    @objc private func recalibrate() {
        tracker.recalibrate()
        overlay.clear()
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        if let angle = sender.representedObject as? Double { startAngle = angle }
    }

    @objc private func startFocus(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        tracker.recalibrate()
        session.start(minutes: minutes)
    }

    @objc private func stopFocus() {
        session.stop()
    }
}

import AppKit
import CoreMotion
import ServiceManagement
import UserNotifications

/// Menü çubuğu uygulaması. Dock'ta görünmez (LSUIElement).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let tracker = HeadTracker()
    private let overlay = OverlayController()
    private let session = FocusSession()
    private let hotKeys = HotKeys()
    private var statsWindow: StatsWindowController?

    // Eşikler
    private var screenMargin: Double { [0, 6, 14][max(0, min(2, Prefs.screenSize))] }
    private var effectiveStart: Double { Prefs.startAngle + screenMargin }
    /// Başlangıçtan 22° sonra şerit tam (yarım ekran).
    private var fullAngle: Double { effectiveStart + 22 }
    /// Odak modunda "ekrandan uzaklaştı" eşiği. Yukarı bakış sayılmaz.
    private var awayAngle: Double { 35 + screenMargin }

    private var connected = false
    private var lastPose = HeadTracker.Pose(yaw: 0, pitch: 0, rate: 0)
    private var smoothedFraction: Double = 0
    private var fractionVelocity: Double = 0
    private var currentSide = -1
    private var sampleCount = 0

    /// Öndeki uygulama "kapat" listesindeyse bulanıklık askıda.
    private var suspendedByApp = false

    // Kafa hareketleri
    private var spaceArmed = true
    private var lastSpaceSwitch = Date.distantPast
    private var postureSince: Date?
    private var postureWarned = false
    private var dwellAnchor: CGPoint?
    private var dwellSince: Date?
    private var dwellArmed = true

    private var menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sessionLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let appsMenu = NSMenu(title: "Şu uygulamalarda kapat")

    private enum Tag: Int {
        case toggle = 1, sensitivity, focusStart, focusStop, screenSize, invert, strength, glass, radius
        case screens, breakToggle, mute, dnd, returnNote, headScroll, headSpace, posture, heatmap
        case headMouse, dwell, accessibility, loginItem
    }

    // MARK: Yaşam döngüsü

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.menu = menu
        menu.delegate = self
        buildMenu()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        tracker.onAvailabilityChange = { [weak self] available in
            self?.connected = available
            if !available { self?.overlay.clear() }
            self?.refreshMenu()
        }
        tracker.onPose = { [weak self] pose in self?.handle(pose) }
        session.onChange = { [weak self] in self?.sessionChanged() }
        session.onReturn = { [weak self] in self?.sessionReturned() }
        session.onFinished = { [weak self] wasBreak in self?.sessionFinished(wasBreak: wasBreak) }

        overlay.strength = Prefs.strength
        overlay.kind = GlassKind(rawValue: Prefs.glassKind) ?? .liquid
        overlay.screenMode = Prefs.screenMode
        overlay.onCaptureStateChange = { [weak self] in self?.refreshMenu() }
        overlay.radius = Prefs.blurRadius > 0 ? Prefs.blurRadius : nil

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        frontAppChanged(nil)

        registerHotKeys()

        connected = tracker.isAvailable
        tracker.start()
        refreshMenu()
    }

    private func registerHotKeys() {
        hotKeys.register(HotKeys.focus) { [weak self] in self?.toggleFocusFromHotKey() }
        hotKeys.register(HotKeys.blur) { [weak self] in self?.toggleEnabled() }
        hotKeys.register(HotKeys.recenter) { [weak self] in self?.recalibrate() }
        hotKeys.register(HotKeys.stats) { [weak self] in self?.openStats() }
    }

    // MARK: Kafa verisi

    private func handle(_ pose: HeadTracker.Pose) {
        lastPose = pose
        sampleCount += 1
        if !connected { connected = true; refreshMenu() }

        if Prefs.heatmap, sampleCount % 10 == 0 {
            Stats.shared.recordGaze(yaw: pose.yaw, pitch: pose.pitch)
        }

        let away = abs(pose.yaw) >= awayAngle || pose.pitch <= -awayAngle
        session.update(away: away)

        handlePosture(pose)
        handleHeadMouse(pose)
        handleHeadScroll(pose)
        handleSpaceSwitch(pose)

        if session.state == .paused {
            var message = "Ekrana dön · \(session.remainingLabel) duraklatıldı"
            if Prefs.returnNote, let note = session.note, !note.isEmpty { message += "\n\(note)" }
            overlay.showFull(message: message)
            if Prefs.muteOnAway { SystemActions.muteOutput() }
            return
        }
        if Prefs.muteOnAway { SystemActions.restoreOutput() }

        guard Prefs.enabled, !suspendedByApp else { overlay.clear(); return }

        let magnitude = abs(pose.yaw)
        let target: Double
        if magnitude < effectiveStart {
            target = 0
        } else {
            let t = min(1, (magnitude - effectiveStart) / (fullAngle - effectiveStart))
            target = 0.08 + 0.42 * t
        }
        // Yaylı yumuşatma: açılış hafif ivmelenip yavaşça oturuyor, kapanış
        // biraz daha hızlı.
        let stiffness = target > smoothedFraction ? 0.18 : 0.28
        fractionVelocity = fractionVelocity * 0.72 + (target - smoothedFraction) * stiffness
        smoothedFraction += fractionVelocity
        smoothedFraction = min(max(smoothedFraction, 0), 0.6)
        if smoothedFraction < 0.01, target == 0 { smoothedFraction = 0; fractionVelocity = 0 }

        if smoothedFraction == 0 {
            overlay.showSide(fraction: 0, side: 0)
            return
        }
        // Bakılmayan taraf bulanır: sola dönünce sağ, sağa dönünce sol.
        if magnitude >= effectiveStart {
            let lookingRight = pose.yaw < 0
            currentSide = (lookingRight ? 1 : -1) * (Prefs.invertSide ? -1 : 1)
        }
        overlay.showSide(fraction: smoothedFraction, side: currentSide)
    }

    /// Duruş: kafa belirli süre öne eğik kalınca nazik hatırlatma. Kaldırınca
    /// sıfırlanır; süre boyunca bir kez uyarır.
    private func handlePosture(_ pose: HeadTracker.Pose) {
        let minutes = Prefs.postureMinutes
        guard minutes > 0 else { postureSince = nil; return }
        if pose.pitch <= -15 {
            if postureSince == nil { postureSince = Date() }
            if !postureWarned, let since = postureSince,
               Date().timeIntervalSince(since) >= Double(minutes) * 60 {
                postureWarned = true
                HudWindow.show("Başını biraz kaldır 🙂  \(minutes) dakikadır öne eğik.", seconds: 4)
                let content = UNMutableNotificationContent()
                content.title = "Duruş"
                content.body = "\(minutes) dakikadır başın öne eğik. Omuzları geri, çeneyi hafif yukarı."
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        } else if pose.pitch > -8 {
            postureSince = nil
            postureWarned = false
        }
    }

    /// Kafayla kaydırma: aşağı eğince sayfa aşağı, yukarı kaldırınca yukarı.
    /// Ölü bölge 14°; hız açıyla artıyor.
    private func handleHeadScroll(_ pose: HeadTracker.Pose) {
        guard Prefs.headScroll, session.state != .paused, SystemActions.accessibilityGranted else { return }
        let dead = 14.0
        let p = pose.pitch
        guard abs(p) > dead else { return }
        let excess = min(30, abs(p) - dead)
        let pixels = Int32((excess * 0.9).rounded())
        SystemActions.scroll(pixels: p < 0 ? -pixels : pixels)
    }

    /// Kafayla masaüstü geçişi: 50°'yi hızlı geçince bir sonraki/önceki
    /// Space. Tetiklenince yeniden kurulmak için 30°'nin altına inmek gerek.
    private func handleSpaceSwitch(_ pose: HeadTracker.Pose) {
        guard Prefs.headSpace, session.state != .paused, SystemActions.accessibilityGranted else { return }
        let threshold = 50 + screenMargin
        if abs(pose.yaw) < 30 { spaceArmed = true; return }
        guard spaceArmed, abs(pose.yaw) >= threshold, pose.rate > 0.6,
              Date().timeIntervalSince(lastSpaceSwitch) > 1.5 else { return }
        spaceArmed = false
        lastSpaceSwitch = Date()
        SystemActions.switchSpace(right: pose.yaw < 0)
    }

    /// Kafayla imleç: düz bakış ekranın ortası, ±25° ekranın kenarları.
    /// Sabit bakınca tıklama: imleç 1,2 sn yerinde durursa tıklar; yeniden
    /// tıklamak için 20 pikselden fazla hareket gerekir.
    private func handleHeadMouse(_ pose: HeadTracker.Pose) {
        guard Prefs.headMouse, session.state != .paused, SystemActions.accessibilityGranted,
              let screen = NSScreen.main else { dwellSince = nil; return }
        let frame = screen.frame
        let nx = max(-1, min(1, -pose.yaw / 25))
        let ny = max(-1, min(1, -pose.pitch / 18))
        // CGEvent koordinatı sol üstten; NSScreen sol alttan.
        let global = NSPoint(x: frame.midX + nx * frame.width / 2, y: frame.midY - ny * frame.height / 2)
        let flippedY = (NSScreen.screens.first?.frame.maxY ?? frame.maxY) - global.y
        let point = CGPoint(x: global.x, y: flippedY)
        SystemActions.moveMouse(to: point)

        guard Prefs.dwellClick else { return }
        if let anchor = dwellAnchor, hypot(anchor.x - point.x, anchor.y - point.y) < 12 {
            if dwellArmed, let since = dwellSince, Date().timeIntervalSince(since) >= 1.2 {
                dwellArmed = false
                SystemActions.click(at: point)
            }
        } else {
            if let anchor = dwellAnchor, hypot(anchor.x - point.x, anchor.y - point.y) > 20 { dwellArmed = true }
            dwellAnchor = point
            dwellSince = Date()
        }
    }

    // MARK: Odak oturumu

    private func sessionChanged() {
        switch session.state {
        case .finished, .idle:
            overlay.clear()
            statusItem.button?.title = ""
            statusItem.button?.image = StatusIcon.make()
            if Prefs.muteOnAway { SystemActions.restoreOutput() }
        case .running:
            statusItem.button?.title = (session.isBreak ? " ☕ " : " ") + session.remainingLabel
            statusItem.button?.image = StatusIcon.make()
        case .paused:
            statusItem.button?.title = " " + session.remainingLabel
            statusItem.button?.image = StatusIcon.make(paused: true)
        }
        refreshMenu()
    }

    private func sessionReturned() {
        overlay.clear()
        if Prefs.muteOnAway { SystemActions.restoreOutput() }
        if Prefs.returnNote, let note = session.note, !note.isEmpty {
            HudWindow.show("Kaldığın yer: \(note)")
        }
    }

    private func sessionFinished(wasBreak: Bool) {
        if wasBreak { return }
        if Prefs.dndOnFocus { SystemActions.setDoNotDisturb(false) }
        if Prefs.breakEnabled {
            HudWindow.show("Odak bitti · \(Prefs.breakMinutes) dakika mola", seconds: 3)
            session.start(minutes: Prefs.breakMinutes, isBreak: true)
        }
    }

    private func startFocus(minutes: Int) {
        var note: String?
        if Prefs.returnNote {
            note = askText(title: "Ne üzerinde çalışıyorsun?",
                           message: "Ekrandan uzaklaşıp dönünce hatırlatılır. Boş bırakabilirsin.",
                           placeholder: "örn. rapor taslağı, 3. bölüm")
        }
        tracker.recalibrate()
        session.note = note
        session.start(minutes: minutes)
        if Prefs.dndOnFocus { SystemActions.setDoNotDisturb(true) }
    }

    private func toggleFocusFromHotKey() {
        if session.state == .running || session.state == .paused {
            stopFocus()
        } else {
            startFocus(minutes: 25)
        }
    }

    // MARK: Uygulama dışlama

    @objc private func frontAppChanged(_ notification: Notification?) {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let suspended = Prefs.excludedApps.contains(bundle)
        if suspended != suspendedByApp {
            suspendedByApp = suspended
            if suspended { overlay.clear() }
            refreshMenu()
        }
    }

    // MARK: Menü

    private func buildMenu() {
        menu.removeAllItems()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        add("Yan bulanıklık", #selector(toggleEnabled), tag: .toggle, shortcut: HotKeys.blur.label)
        add("Düz bakışı sıfırla", #selector(recalibrate), tag: nil, shortcut: HotKeys.recenter.label)

        // Bulanıklık
        let radiusMenu = NSMenu(title: "Bulanıklık")
        for (title, value) in Self.radiusOptions {
            radiusMenu.addItem(item(title, #selector(setRadius(_:)), object: value))
        }
        addSub("Bulanıklık", radiusMenu, tag: .radius)

        let glassMenu = NSMenu(title: "Cam türü")
        for kind in GlassKind.allCases where kind.available {
            glassMenu.addItem(item(kind.title, #selector(setGlass(_:)), object: kind.rawValue))
        }
        addSub("Cam türü", glassMenu, tag: .glass)

        let powerMenu = NSMenu(title: "Bulanıklık gücü")
        for (index, title) in ["Hafif", "Normal", "Güçlü"].enumerated() {
            powerMenu.addItem(item(title, #selector(setStrength(_:)), object: index + 1))
        }
        addSub("Bulanıklık gücü", powerMenu, tag: .strength)

        // Görünüm
        let look = NSMenu(title: "Görünüm")
        look.addItem(item("Yönü ters çevir (bakılan taraf bulansın)", #selector(toggleInvert), object: nil, tag: .invert))
        look.addItem(subItem("Hassasiyet", tag: .sensitivity, entries: [
            ("Yüksek (8°)", 8.0), ("Normal (12°)", 12.0), ("Düşük (20°)", 20.0),
        ], action: #selector(setSensitivity(_:))))
        look.addItem(subItem("Ekran boyutu", tag: .screenSize, entries: [
            ("Dizüstü", 0), ("Masaüstü", 1), ("Büyük ekran", 2),
        ], action: #selector(setScreenSize(_:))))
        look.addItem(subItem("Hangi ekranlar", tag: .screens, entries: [
            ("Tüm ekranlar", 0), ("Yalnızca ana ekran", 1), ("İmlecin olduğu ekran", 2),
        ], action: #selector(setScreenMode(_:))))
        addSub("Görünüm", look, tag: nil)

        appsMenu.delegate = self
        addSub("Şu uygulamalarda kapat", appsMenu, tag: nil)

        menu.addItem(.separator())
        sessionLine.isEnabled = false
        menu.addItem(sessionLine)

        // Odak
        let focus = NSMenu(title: "Odak modu")
        for minutes in [15, 25, 50] {
            focus.addItem(item("\(minutes) dakika", #selector(startFocusItem(_:)), object: minutes))
        }
        focus.addItem(item("Özel süre…", #selector(startFocusCustom), object: nil))
        focus.addItem(.separator())
        focus.addItem(item("Odak bitince mola sayacı (\(Prefs.breakMinutes) dk)", #selector(toggleBreak), object: nil, tag: .breakToggle))
        focus.addItem(item("Uzaklaşınca sesi kıs", #selector(toggleMute), object: nil, tag: .mute))
        focus.addItem(item("Odak sırasında Rahatsız Etmeyin", #selector(toggleDnd), object: nil, tag: .dnd))
        focus.addItem(item("Dönüşte notumu hatırlat", #selector(toggleReturnNote), object: nil, tag: .returnNote))
        addSub("Odak modu", focus, tag: .focusStart)
        add("Odak modunu bitir", #selector(stopFocus), tag: .focusStop, shortcut: HotKeys.focus.label)
        add("İstatistikler…", #selector(openStats), tag: nil, shortcut: HotKeys.stats.label)

        menu.addItem(.separator())

        // Kafa hareketleri
        let head = NSMenu(title: "Kafa hareketleri")
        head.addItem(item("Kafayla kaydırma (eğ: aşağı / kaldır: yukarı)", #selector(toggleHeadScroll), object: nil, tag: .headScroll))
        head.addItem(item("Kafayla masaüstü geçişi (sert çevir)", #selector(toggleHeadSpace), object: nil, tag: .headSpace))
        head.addItem(subItem("Duruş uyarısı", tag: .posture, entries: [
            ("Kapalı", 0), ("3 dakika", 3), ("5 dakika", 5), ("10 dakika", 10),
        ], action: #selector(setPosture(_:))))
        head.addItem(item("Dikkat ısı haritasını tut", #selector(toggleHeatmap), object: nil, tag: .heatmap))
        head.addItem(.separator())
        head.addItem(item("Kafayla imleç", #selector(toggleHeadMouse), object: nil, tag: .headMouse))
        head.addItem(item("Sabit bakınca tıkla", #selector(toggleDwell), object: nil, tag: .dwell))
        head.addItem(.separator())
        head.addItem(item("Erişilebilirlik izni ver…", #selector(requestAccessibility), object: nil, tag: .accessibility))
        addSub("Kafa hareketleri", head, tag: nil)

        menu.addItem(.separator())
        add("Açılışta başlat", #selector(toggleLoginItem), tag: .loginItem, shortcut: nil)
        let quit = NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        refreshMenu()
    }

    private static let radiusOptions: [(String, Double)] = [
        ("Tam · sistem camı", 0),
        ("xs · 4 px", 4), ("sm · 8 px", 8), ("md · 12 px", 12), ("lg · 16 px", 16),
        ("xl · 24 px", 24), ("2xl · 40 px", 40), ("3xl · 64 px", 64),
    ]

    private func item(_ title: String, _ action: Selector, object: Any?, tag: Tag? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        if let tag { item.tag = tag.rawValue }
        return item
    }

    private func subItem(_ title: String, tag: Tag, entries: [(String, Any)], action: Selector) -> NSMenuItem {
        let sub = NSMenu(title: title)
        for (label, value) in entries { sub.addItem(item(label, action, object: value)) }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = sub
        holder.tag = tag.rawValue
        return holder
    }

    private func add(_ title: String, _ action: Selector, tag: Tag?, shortcut: String?) {
        let item = NSMenuItem(title: shortcut.map { "\(title)   \($0)" } ?? title, action: action, keyEquivalent: "")
        item.target = self
        if let tag { item.tag = tag.rawValue }
        menu.addItem(item)
    }

    private func addSub(_ title: String, _ submenu: NSMenu, tag: Tag?) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        if let tag { item.tag = tag.rawValue }
        menu.addItem(item)
    }

    private func find(_ tag: Tag) -> NSMenuItem? {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.tag == tag.rawValue { return item }
                if let sub = item.submenu, let found = search(sub) { return found }
            }
            return nil
        }
        return search(menu)
    }

    private func check(_ tag: Tag, _ on: Bool) { find(tag)?.state = on ? .on : .off }

    private func checkChoice(_ tag: Tag, _ value: AnyHashable) {
        guard let sub = find(tag)?.submenu else { return }
        for item in sub.items {
            item.state = (item.representedObject as? AnyHashable) == value ? .on : .off
        }
    }

    private func refreshMenu() {
        let auth = tracker.authorization
        if auth == .denied || auth == .restricted {
            statusLine.title = "Hareket izni yok · Sistem Ayarları → Gizlilik → Hareket ve Fitness"
        } else if overlay.captureFailed {
            statusLine.title = "Ekran kaydı izni yok · Sistem Ayarları → Gizlilik → Ekran Kaydı"
        } else if !tracker.isAvailable {
            statusLine.title = "Destekleyen kulaklık yok"
        } else if !connected {
            statusLine.title = "AirPods bekleniyor"
        } else if suspendedByApp {
            statusLine.title = "Bu uygulamada kapalı"
        } else {
            statusLine.title = String(format: "Bağlı · yön %+.0f° · eğim %+.0f°", lastPose.yaw, lastPose.pitch)
        }

        check(.toggle, Prefs.enabled)
        check(.invert, Prefs.invertSide)
        checkChoice(.sensitivity, Prefs.startAngle)
        checkChoice(.screenSize, Prefs.screenSize)
        checkChoice(.screens, Prefs.screenMode)
        checkChoice(.radius, Prefs.blurRadius)
        checkChoice(.glass, Prefs.glassKind)
        checkChoice(.strength, Prefs.strength)
        find(.glass)?.isHidden = Prefs.blurRadius > 0
        find(.strength)?.isHidden = Prefs.blurRadius > 0

        check(.breakToggle, Prefs.breakEnabled)
        check(.mute, Prefs.muteOnAway)
        check(.dnd, Prefs.dndOnFocus)
        check(.returnNote, Prefs.returnNote)
        check(.headScroll, Prefs.headScroll)
        check(.headSpace, Prefs.headSpace)
        checkChoice(.posture, Prefs.postureMinutes)
        check(.heatmap, Prefs.heatmap)
        check(.headMouse, Prefs.headMouse)
        check(.dwell, Prefs.dwellClick)
        find(.accessibility)?.isHidden = SystemActions.accessibilityGranted
        check(.loginItem, SMAppService.mainApp.status == .enabled)

        let running = session.state == .running || session.state == .paused
        sessionLine.title = switch session.state {
        case .idle: "Odak modu kapalı"
        case .running: session.isBreak ? "Mola · kalan \(session.remainingLabel)" : "Odak · kalan \(session.remainingLabel)"
        case .paused: "Odak duraklatıldı · ekrana dön"
        case .finished: "Odak süresi tamamlandı"
        }
        find(.focusStart)?.isHidden = running
        find(.focusStop)?.isHidden = !running
        find(.focusStop)?.title = (session.isBreak ? "Molayı bitir" : "Odak modunu bitir") + "   \(HotKeys.focus.label)"
    }

    /// "Şu uygulamalarda kapat" açılırken çalışan uygulamaları listeler.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === appsMenu else { return }
        menu.removeAllItems()
        let excluded = Set(Prefs.excludedApps)
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in running {
            guard let bundle = app.bundleIdentifier else { continue }
            let entry = item(app.localizedName ?? bundle, #selector(toggleExcludedApp(_:)), object: bundle)
            entry.state = excluded.contains(bundle) ? .on : .off
            if let icon = app.icon { icon.size = NSSize(width: 16, height: 16); entry.image = icon }
            menu.addItem(entry)
        }
        // Çalışmayan ama listede olanlar da görünsün ki kaldırılabilsin.
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        let stale = excluded.subtracting(runningIDs).sorted()
        if !stale.isEmpty {
            menu.addItem(.separator())
            for bundle in stale {
                let entry = item(bundle, #selector(toggleExcludedApp(_:)), object: bundle)
                entry.state = .on
                menu.addItem(entry)
            }
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "Açık uygulama yok", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
    }

    // MARK: Eylemler

    @objc private func toggleEnabled() {
        Prefs.enabled.toggle()
        if !Prefs.enabled { overlay.clear() }
        refreshMenu()
    }

    @objc private func toggleInvert() { Prefs.invertSide.toggle(); refreshMenu() }

    @objc private func recalibrate() {
        tracker.recalibrate()
        overlay.clear()
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        if let angle = sender.representedObject as? Double { Prefs.startAngle = angle; refreshMenu() }
    }

    @objc private func setScreenSize(_ sender: NSMenuItem) {
        if let size = sender.representedObject as? Int { Prefs.screenSize = size; refreshMenu() }
    }

    @objc private func setScreenMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? Int {
            Prefs.screenMode = mode
            overlay.screenMode = mode
            overlay.clear()
            refreshMenu()
        }
    }

    @objc private func setRadius(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double {
            Prefs.blurRadius = value
            overlay.radius = value > 0 ? value : nil
            refreshMenu()
        }
    }

    @objc private func setGlass(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? Int, let kind = GlassKind(rawValue: raw) {
            Prefs.glassKind = raw
            overlay.kind = kind
            refreshMenu()
        }
    }

    @objc private func setStrength(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Int {
            Prefs.strength = value
            overlay.strength = value
            refreshMenu()
        }
    }

    @objc private func toggleExcludedApp(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        var list = Prefs.excludedApps
        if let index = list.firstIndex(of: bundle) { list.remove(at: index) } else { list.append(bundle) }
        Prefs.excludedApps = list
        frontAppChanged(nil)
    }

    @objc private func startFocusItem(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        startFocus(minutes: minutes)
    }

    @objc private func startFocusCustom() {
        guard let text = askText(title: "Kaç dakika?", message: "1 ile 240 arasında.", placeholder: "45"),
              let minutes = Int(text.trimmingCharacters(in: .whitespaces)), (1...240).contains(minutes) else { return }
        startFocus(minutes: minutes)
    }

    @objc private func stopFocus() {
        if Prefs.dndOnFocus, !session.isBreak { SystemActions.setDoNotDisturb(false) }
        session.stop()
    }

    @objc private func toggleBreak() { Prefs.breakEnabled.toggle(); refreshMenu() }
    @objc private func toggleMute() {
        Prefs.muteOnAway.toggle()
        if !Prefs.muteOnAway { SystemActions.restoreOutput() }
        refreshMenu()
    }
    @objc private func toggleDnd() { Prefs.dndOnFocus.toggle(); refreshMenu() }
    @objc private func toggleReturnNote() { Prefs.returnNote.toggle(); refreshMenu() }

    @objc private func openStats() {
        if statsWindow == nil { statsWindow = StatsWindowController() }
        statsWindow?.refresh()
        statsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        statsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleHeadScroll() { Prefs.headScroll.toggle(); if Prefs.headScroll { SystemActions.ensureAccessibility() }; refreshMenu() }
    @objc private func toggleHeadSpace() { Prefs.headSpace.toggle(); if Prefs.headSpace { SystemActions.ensureAccessibility() }; refreshMenu() }
    @objc private func setPosture(_ sender: NSMenuItem) {
        if let minutes = sender.representedObject as? Int { Prefs.postureMinutes = minutes; postureSince = nil; postureWarned = false; refreshMenu() }
    }
    @objc private func toggleHeatmap() { Prefs.heatmap.toggle(); refreshMenu() }
    @objc private func toggleHeadMouse() { Prefs.headMouse.toggle(); if Prefs.headMouse { SystemActions.ensureAccessibility() }; refreshMenu() }
    @objc private func toggleDwell() { Prefs.dwellClick.toggle(); refreshMenu() }
    @objc private func requestAccessibility() {
        SystemActions.ensureAccessibility()
        refreshMenu()
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("HeadFocus: açılışta başlat ayarlanamadı: \(error)")
        }
        refreshMenu()
    }

    // MARK: Yardımcı

    /// Basit metin sorusu. Menü çubuğu uygulaması olduğu için önce öne alınır.
    private func askText(title: String, message: String, placeholder: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Tamam")
        alert.addButton(withTitle: "Vazgeç")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

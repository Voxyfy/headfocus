import AppKit

/// Her ekranın üstünde duran, tıklamaları geçiren şeffaf pencere. İçindeki
/// blur görünümü arkasındaki her şeyi (başka uygulamalar dahil) bulanıklaştırır.
///
/// İki kip:
/// - Yan blur: kafanın döndüğü tarafta, dönüş açısıyla genişleyen şerit.
/// - Tam blur (odak modu, ekrandan uzaklaşınca): bütün ekran + mesaj.
/// Cam türü. Sistem bulanıklığının yarıçapı sabit; his malzemeyle değişiyor.
enum GlassKind: Int, CaseIterable {
    case frostedDark = 0   // koyu buzlu cam (HUD)
    case frostedLight      // açık buzlu cam (popover)
    case clear             // sade bulanıklık, renk katmaz
    case liquid            // macOS 26+ Liquid Glass (kırılma + kenar ışığı)

    var title: String {
        switch self {
        case .frostedDark: "Buzlu cam · koyu"
        case .frostedLight: "Buzlu cam · açık"
        case .clear: "Sade bulanıklık"
        case .liquid: "Liquid Glass"
        }
    }

    var material: NSVisualEffectView.Material {
        switch self {
        case .frostedDark: .hudWindow
        case .frostedLight: .popover
        case .clear, .liquid: .fullScreenUI
        }
    }

    var available: Bool {
        if case .liquid = self {
            if #available(macOS 26.0, *) { return true }
            return false
        }
        return true
    }
}

final class OverlayWindow: NSWindow {
    let screenFrame: NSRect
    private let blur = NSVisualEffectView()
    private let dim = NSView()
    /// Liquid Glass katmanı (yalnızca `.liquid`); blur görünümünün üstünde.
    private var glass: NSView?

    /// Yakalanıp bulanıklaştırılmış ekran görüntüsü (yarıçap kipinde).
    /// Tam ekran duruyor, görünen bölge maske ile kesiliyor.
    private let picture = NSView()
    private var pictureMode = false {
        didSet {
            picture.isHidden = !pictureMode
            blur.isHidden = pictureMode
            glass?.isHidden = pictureMode
        }
    }

    func setPicture(_ image: CGImage?) {
        picture.layer?.contents = image
    }

    func usePicture(_ on: Bool) { pictureMode = on }

    var kind: GlassKind = .liquid {
        didSet { applyKind() }
    }

    private func applyKind() {
        blur.material = kind.material
        glass?.removeFromSuperview()
        glass = nil
        if kind == .liquid, #available(macOS 26.0, *), let content = contentView {
            let view = NSGlassEffectView()
            view.style = .regular
            view.cornerRadius = 0
            view.contentView = NSView()
            view.frame = .zero
            content.addSubview(view, positioned: .above, relativeTo: blur)
            glass = view
        }
    }

    /// Karartma oranı (0…1); OverlayController güç ayarına göre veriyor.
    var dimAmount: CGFloat = 0
    private let messageLabel = NSTextField(labelWithString: "")
    private let messageBox = NSVisualEffectView()

    init(screen: NSScreen) {
        screenFrame = screen.frame
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.setFrame(screen.frame, display: false)

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        contentView = content

        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.frame = .zero
        content.addSubview(blur)

        picture.wantsLayer = true
        picture.layer?.contentsGravity = .resize
        picture.frame = content.bounds
        picture.autoresizingMask = [.width, .height]
        picture.isHidden = true
        content.addSubview(picture, positioned: .above, relativeTo: blur)

        // Karartma: bulanıklığın üstüne hafif siyah. Bulanıklık tek başına
        // "orası kapalı" hissi vermiyordu; bir tık karartınca fark oluyor.
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.cgColor
        dim.alphaValue = 0
        dim.frame = .zero
        content.addSubview(dim)

        messageBox.material = .hudWindow
        messageBox.blendingMode = .withinWindow
        messageBox.state = .active
        messageBox.wantsLayer = true
        messageBox.layer?.cornerRadius = 18
        messageBox.isHidden = true
        content.addSubview(messageBox)

        messageLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        messageLabel.textColor = .labelColor
        messageLabel.alignment = .center
        messageBox.addSubview(messageLabel)

        orderFrontRegardless()
    }

    /// Yan şerit. `fraction` 0…1 ekranın ne kadarının bulanacağı; `side`
    /// negatif = sağ, pozitif = sol, 0 = kapalı.
    func showSide(fraction: CGFloat, side: Int) {
        messageBox.isHidden = true
        guard fraction > 0, side != 0, let content = contentView else {
            blur.frame = .zero
            blur.alphaValue = 0
            glass?.frame = .zero
            picture.alphaValue = 0
            dim.frame = .zero
            dim.alphaValue = 0
            return
        }

        let width = content.bounds.width * min(max(fraction, 0), 1)
        let x = side < 0 ? content.bounds.width - width : 0
        blur.frame = NSRect(x: x, y: 0, width: width, height: content.bounds.height)
        // İç kenarda yumuşak geçiş: maske görseli kenarda saydamdan opağa
        // gidiyor, gerisi düz. capInsets sayesinde geçiş bandı şerit
        // genişlese de sabit kalıyor.
        blur.maskImage = side < 0 ? Self.rightMask : Self.leftMask
        blur.alphaValue = 1
        glass?.frame = blur.frame
        glass?.alphaValue = 1
        dim.frame = blur.frame
        dim.layer?.mask = nil
        dim.alphaValue = dimAmount
        applyDimMask(side: side)
        if pictureMode {
            picture.layer?.mask = Self.featherMask(for: blur.frame, in: content.bounds, side: side)
            picture.alphaValue = 1
        }
    }

    /// Resim katmanı tam ekran; yalnızca şerit bölgesi, yumuşak kenarla.
    private static func featherMask(for strip: NSRect, in bounds: NSRect, side: Int) -> CALayer {
        let gradient = CAGradientLayer()
        gradient.frame = strip
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        let f = min(1, feather / max(strip.width, 1))
        if side < 0 {
            gradient.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
            gradient.locations = [0, NSNumber(value: Double(f)), 1]
        } else {
            gradient.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            gradient.locations = [0, NSNumber(value: Double(1 - f)), 1]
        }
        return gradient
    }

    /// Karartmaya da aynı yumuşak kenar; yoksa bulanıklık yumuşak, karartma
    /// sert başlıyor ve çizgi yine görünüyor.
    private func applyDimMask(side: Int) {
        guard dimAmount > 0, let layer = dim.layer else { return }
        let gradient = CAGradientLayer()
        gradient.frame = layer.bounds
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        let f = min(1, Self.feather / max(layer.bounds.width, 1))
        if side < 0 {
            gradient.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
            gradient.locations = [0, NSNumber(value: Double(f)), 1]
        } else {
            gradient.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            gradient.locations = [0, NSNumber(value: Double(1 - f)), 1]
        }
        layer.mask = gradient
    }

    /// Geçiş bandının genişliği (piksel).
    private static let feather: CGFloat = 220

    /// Sağ şerit için maske: sol kenarda saydam → sağa doğru opak.
    private static let rightMask: NSImage = makeMask(fadeOnLeft: true)
    /// Sol şerit için maske: sağ kenarda saydam → sola doğru opak.
    private static let leftMask: NSImage = makeMask(fadeOnLeft: false)

    private static func makeMask(fadeOnLeft: Bool) -> NSImage {
        let size = NSSize(width: feather + 2, height: 2)
        let image = NSImage(size: size, flipped: false) { rect in
            let gradient = NSGradient(colors: [
                NSColor.black.withAlphaComponent(0),
                NSColor.black.withAlphaComponent(1),
            ])!
            // Yumuşak (ease) geçiş: düz doğrusal maske hâlâ çizgi gibi duruyor.
            let steps = 16
            var colors: [NSColor] = []
            var locations: [CGFloat] = []
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let eased = t * t * (3 - 2 * t)
                colors.append(NSColor.black.withAlphaComponent(eased))
                locations.append(t)
            }
            let smooth = NSGradient(colors: colors, atLocations: locations, colorSpace: .deviceRGB) ?? gradient
            let fadeRect = NSRect(x: fadeOnLeft ? 0 : 2, y: 0, width: feather, height: rect.height)
            smooth.draw(in: fadeRect, angle: fadeOnLeft ? 0 : 180)
            NSColor.black.setFill()
            NSRect(x: fadeOnLeft ? feather : 0, y: 0, width: 2, height: rect.height).fill()
            return true
        }
        image.resizingMode = .stretch
        image.capInsets = fadeOnLeft
            ? NSEdgeInsets(top: 0, left: feather, bottom: 0, right: 1)
            : NSEdgeInsets(top: 0, left: 1, bottom: 0, right: feather)
        return image
    }

    func showFull(message: String) {
        guard let content = contentView else { return }
        blur.maskImage = nil
        blur.frame = content.bounds
        blur.alphaValue = 1
        glass?.frame = content.bounds
        if pictureMode { picture.layer?.mask = nil; picture.alphaValue = 1 }
        dim.frame = content.bounds
        dim.layer?.mask = nil
        dim.alphaValue = max(dimAmount, 0.2)
        messageLabel.stringValue = message
        messageLabel.sizeToFit()
        let box = NSRect(
            x: (content.bounds.width - messageLabel.frame.width - 80) / 2,
            y: (content.bounds.height - 90) / 2,
            width: messageLabel.frame.width + 80,
            height: 90
        )
        messageBox.frame = box
        messageLabel.frame = NSRect(x: 40, y: (90 - messageLabel.frame.height) / 2,
                                    width: messageLabel.frame.width, height: messageLabel.frame.height)
        messageBox.isHidden = false
    }

    func clear() {
        blur.frame = .zero
        blur.alphaValue = 0
        glass?.frame = .zero
        picture.alphaValue = 0
        dim.frame = .zero
        dim.alphaValue = 0
        messageBox.isHidden = true
    }
}

/// Bağlı tüm ekranlar için kaplamaları yönetir; ekran takılıp çıkınca
/// yeniden kurar.
final class OverlayController {
    private var windows: [OverlayWindow] = []
    private var observer: NSObjectProtocol?

    /// Bulanıklık gücü 1…3. Sistem efektinin yarıçapı sabit; güç, karartma
    /// ve katman sayısıyla veriliyor.
    var strength: Int = 2 { didSet { if strength != oldValue { rebuild() } } }
    var kind: GlassKind = .liquid {
        didSet { windows.forEach { $0.kind = kind } }
    }

    /// Bulanıklık yarıçapı (piksel). nil = sistem camı (yarıçap sabit).
    /// Değer verilince ekran yakalanıp CoreImage ile bulanıklaştırılıyor;
    /// tek katman yeter, kademeleme yakalama kipinde kapalı.
    var radius: Double? { didSet { if radius != oldValue { rebuild() } } }

    /// Yakalama izni reddedildi ya da başlatılamadı; menü satırı bunu söyler.
    private(set) var captureFailed = false
    var onCaptureStateChange: (() -> Void)?

    private var sources: [CGDirectDisplayID: ScreenBlurSource] = [:]
    private var visible = false

    /// Kademeli bulanıklık (iPhone Duo'nun katlanma geçişinden esinle):
    /// üst üste birkaç pencere, her biri şeridin kenara yakın bir parçasını
    /// örtüyor. Behind-window blur alttaki pencerenin çıktısını yeniden
    /// bulandırdığı için içeriden dışarıya doğru bulanıklık artıyor; tek
    /// katmanlı düz bulanıklık "cam levha" gibi duruyordu, bu daha çok
    /// "derinlik" gibi. Katman sayısı güçle: 2 / 3 / 4.
    private var layerCount: Int { radius == nil ? [0, 2, 3, 4][max(1, min(3, strength))] : 1 }
    private var dimAmount: CGFloat { [0, 0.04, 0.12, 0.2][max(1, min(3, strength))] }

    /// Her katmanın şerit genişliğine oranı: ilk katman tam şerit, sonrakiler
    /// kenara doğru daralıyor.
    private func layerScale(_ index: Int) -> CGFloat {
        let n = CGFloat(layerCount)
        return 1 - CGFloat(index) / n * 0.75
    }

    init() {
        rebuild()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() }
    }

    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        sources.values.forEach { $0.stop() }
        sources = [:]
        captureFailed = false

        for screen in NSScreen.screens {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) }
            var screenWindows: [OverlayWindow] = []
            for index in 0..<layerCount {
                let window = OverlayWindow(screen: screen)
                window.kind = kind
                // Karartma yalnızca en üstteki pencerede; iki kez karartmak
                // fazla koyu oluyor.
                window.dimAmount = index == layerCount - 1 ? dimAmount : 0
                window.usePicture(radius != nil)
                windows.append(window)
                screenWindows.append(window)
            }

            if let radius, let displayID {
                let source = ScreenBlurSource(displayID: displayID, radius: radius)
                source.onFrame = { image in screenWindows.forEach { $0.setPicture(image) } }
                source.active = visible
                sources[displayID] = source
                Task { @MainActor [weak self] in
                    let ok = await source.start()
                    if !ok, let self {
                        self.captureFailed = true
                        // Yakalama yoksa sistem camına düş, kullanıcı boş şerit görmesin.
                        self.windows.forEach { $0.usePicture(false) }
                        self.onCaptureStateChange?()
                    }
                }
            }
        }
    }

    private func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        sources.values.forEach { $0.active = on }
    }

    /// 0 tüm ekranlar, 1 ana ekran, 2 imlecin bulunduğu ekran.
    var screenMode = 0

    private func targets(_ window: OverlayWindow) -> Bool {
        switch screenMode {
        case 1: return NSScreen.screens.first.map { $0.frame == window.screenFrame } ?? true
        case 2: return window.screenFrame.contains(NSEvent.mouseLocation)
        default: return true
        }
    }

    func showSide(fraction: CGFloat, side: Int) {
        setVisible(fraction > 0 && side != 0)
        for (i, window) in windows.enumerated() {
            let index = i % layerCount
            if targets(window) {
                window.showSide(fraction: fraction * layerScale(index), side: side)
            } else {
                window.clear()
            }
        }
    }

    func showFull(message: String) {
        setVisible(true)
        windows.forEach { $0.showFull(message: message) }
    }

    func clear() {
        setVisible(false)
        windows.forEach { $0.clear() }
    }
}


/// Kısa süreli bilgi baloncuğu (dönüş notu, duruş uyarısı). Ana ekranın
/// ortasında, birkaç saniye sonra kendiliğinden kapanır.
final class HudWindow {
    private static var current: NSPanel?
    private static var timer: Timer?

    static func show(_ text: String, seconds: TimeInterval = 2.5) {
        current?.orderOut(nil)
        timer?.invalidate()
        guard let screen = NSScreen.main else { return }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 520
        label.sizeToFit()

        let size = NSSize(width: label.frame.width + 56, height: label.frame.height + 36)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        label.frame = NSRect(x: 28, y: 18, width: label.frame.width, height: label.frame.height)
        effect.addSubview(label)
        panel.contentView = effect

        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.midY + screen.frame.height * 0.18)
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        current = panel
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
    }
}

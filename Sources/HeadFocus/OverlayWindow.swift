import AppKit

/// Her ekranın üstünde duran, tıklamaları geçiren şeffaf pencere. İçindeki
/// blur görünümü arkasındaki her şeyi (başka uygulamalar dahil) bulanıklaştırır.
///
/// İki kip:
/// - Yan blur: kafanın döndüğü tarafta, dönüş açısıyla genişleyen şerit.
/// - Tam blur (odak modu, ekrandan uzaklaşınca): bütün ekran + mesaj.
final class OverlayWindow: NSWindow {
    private let blur = NSVisualEffectView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let messageBox = NSVisualEffectView()

    init(screen: NSScreen) {
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
            return
        }

        let width = content.bounds.width * min(max(fraction, 0), 1)
        let x = side < 0 ? content.bounds.width - width : 0
        blur.frame = NSRect(x: x, y: 0, width: width, height: content.bounds.height)
        // Şeridin kenarı sert durmasın: dar şeritte daha saydam.
        blur.alphaValue = min(1, 0.55 + fraction)
    }

    func showFull(message: String) {
        guard let content = contentView else { return }
        blur.frame = content.bounds
        blur.alphaValue = 1
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
        messageBox.isHidden = true
    }
}

/// Bağlı tüm ekranlar için kaplamaları yönetir; ekran takılıp çıkınca
/// yeniden kurar.
final class OverlayController {
    private var windows: [OverlayWindow] = []
    private var observer: NSObjectProtocol?

    init() {
        rebuild()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() }
    }

    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { OverlayWindow(screen: $0) }
    }

    func showSide(fraction: CGFloat, side: Int) {
        windows.forEach { $0.showSide(fraction: fraction, side: side) }
    }

    func showFull(message: String) {
        windows.forEach { $0.showFull(message: message) }
    }

    func clear() {
        windows.forEach { $0.clear() }
    }
}

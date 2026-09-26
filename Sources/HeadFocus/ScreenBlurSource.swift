import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ScreenCaptureKit

/// Ayarlanabilir yarıçaplı bulanıklık. Sistemin cam efektinde yarıçap
/// seçilemiyor; Tailwind'deki gibi 4-64 piksel ölçeğini verebilmek için
/// ekran ScreenCaptureKit ile yakalanıyor, CoreImage ile bulanıklaştırılıp
/// kaplama penceresine basılıyor. Kendi pencerelerimiz yakalamanın dışında,
/// yoksa geri besleme oluyor.
///
/// Bedeli: Ekran Kaydı izni ve sürekli yakalama. Yakalama yarı çözünürlükte
/// ve şerit görünmüyorken kareler işlenmiyor; Apple silicon'da yük düşük.
final class ScreenBlurSource: NSObject, SCStreamOutput, SCStreamDelegate {
    let displayID: CGDirectDisplayID
    var radius: Double
    var onFrame: ((CGImage) -> Void)?

    /// Şerit kapalıyken false: kareler gelmeye devam eder ama işlenmez.
    var active = false { didSet { if active, let last = lastRaw { process(last) } } }

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "headfocus.capture", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: false])
    private var pixelScale: CGFloat = 1
    private var lastRaw: CIImage?
    private var busy = false

    init(displayID: CGDirectDisplayID, radius: Double) {
        self.displayID = displayID
        self.radius = radius
    }

    /// İzin yoksa ya da ekran bulunamazsa false.
    @discardableResult
    func start() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return false }
            let me = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

            let config = SCStreamConfiguration()
            // Nokta çözünürlüğü (retina'da yarı piksel): bulanıklaştırılacak
            // görüntüde ince ayrıntı zaten gerekmiyor.
            config.width = display.width
            config.height = display.height
            pixelScale = CGFloat(display.width) / CGFloat(CGDisplayPixelsWide(displayID))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            return true
        } catch {
            NSLog("HeadFocus: ekran yakalama başlatılamadı: \(error)")
            return false
        }
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sampleBuffer.imageBuffer else { return }
        // Eksik kare (ekran değişmedi) atlanır.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let status = attachments.first?[.status] as? Int,
           status != SCFrameStatus.complete.rawValue {
            return
        }
        let image = CIImage(cvPixelBuffer: buffer)
        lastRaw = image
        guard active, !busy else { return }
        process(image)
    }

    private func process(_ image: CIImage) {
        busy = true
        // Yarıçap ekran pikseli cinsinden; yakalama nokta çözünürlüğünde.
        let sigma = radius * pixelScale
        let blurred = image
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: image.extent)
        let cg = context.createCGImage(blurred, from: image.extent)
        busy = false
        guard let cg else { return }
        DispatchQueue.main.async { [weak self] in self?.onFrame?(cg) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("HeadFocus: yakalama durdu: \(error)")
        self.stream = nil
    }
}

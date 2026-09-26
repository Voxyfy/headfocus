import CoreMotion
import Foundation

/// AirPods'tan kafa yönü. CoreMotion'ın kulaklık hareket yöneticisi macOS
/// 14'ten beri Mac'te de var; AirPods Pro, AirPods 3 ve sonrası, AirPods
/// Max ve bazı Beats modelleri destekliyor.
///
/// Sağa sola dönüş (yaw) zamanla kayıyor: mutlak bir pusula yok, hesap
/// jiroskoptan birikiyor. Bu yüzden "düz bakış" referansı tutuluyor ve
/// kullanıcı isteyince sıfırlanıyor. Kulaklık ilk bağlandığında da
/// otomatik sıfırlanır.
final class HeadTracker: NSObject, CMHeadphoneMotionManagerDelegate {
    struct Pose {
        /// Referansa göre sağa/sola dönüş, derece. Sağ negatif, sol pozitif
        /// (CoreMotion: üstten bakınca saat yönünün tersi pozitif).
        var yaw: Double
        /// Referansa göre yukarı/aşağı, derece. Aşağı negatif.
        var pitch: Double
        /// Toplam dönüş hızı, rad/s. Ani hareketleri ayırt etmek için.
        var rate: Double
    }

    var onPose: ((Pose) -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?

    private let manager = CMHeadphoneMotionManager()
    private var referenceYaw: Double?
    private var referencePitch: Double?
    private var lastRaw: (yaw: Double, pitch: Double)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var authorization: CMAuthorizationStatus { CMHeadphoneMotionManager.authorizationStatus() }

    override init() {
        super.init()
        manager.delegate = self
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }

        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(motion)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        lastRaw = nil
    }

    /// Şu anki yönü "düz bakış" kabul et.
    func recalibrate() {
        guard let raw = lastRaw else {
            referenceYaw = nil
            referencePitch = nil
            return
        }
        referenceYaw = raw.yaw
        referencePitch = raw.pitch
        lastSample = nil
    }

    private var lastSample: TimeInterval?

    /// Kayma telafisi: kafa sabitken ve ekrana yakın bir yöne bakarken
    /// referans yavaşça o yöne kayar. Varsayım: kullanıcı zamanın çoğunda
    /// ekrana bakıyor, uzun süre sabit duran yön "düz bakış"tır. Böylece
    /// jiroskop kayması kendiliğinden düzeliyor; sık sık elle sıfırlamak
    /// gerekmiyor. Bedeli: ikinci ekrana dakikalarca sabit bakan kullanıcıda
    /// referans oraya kayar; ⌘R ile geri alınır.
    private let driftTau: Double = 6          // saniye; ~3τ sonra tamamen oturur
    private let driftMaxAngle: Double = 25    // bu açıdan uzağa kayma yapılmaz
    private let driftMaxPitch: Double = 8
    private let stillRate: Double = 0.12      // rad/s; altı "kafa sabit"

    private func handle(_ motion: CMDeviceMotion) {
        let yaw = motion.attitude.yaw * 180 / .pi
        let pitch = motion.attitude.pitch * 180 / .pi
        lastRaw = (yaw, pitch)

        let now = motion.timestamp
        let dt = lastSample.map { min(max(now - $0, 0), 0.5) } ?? 0
        lastSample = now

        if referenceYaw == nil {
            referenceYaw = yaw
            referencePitch = pitch
        }

        var relYaw = Self.wrap(yaw - (referenceYaw ?? yaw))
        var relPitch = pitch - (referencePitch ?? pitch)

        let r = motion.rotationRate
        let rate = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        if rate < stillRate, abs(relYaw) < driftMaxAngle, dt > 0 {
            let k = 1 - exp(-dt / driftTau)
            referenceYaw = (referenceYaw ?? yaw) + relYaw * k
            relYaw = Self.wrap(yaw - referenceYaw!)
            // Eğim için dar pencere: öne eğik duruş referansa yerleşmesin,
            // yoksa duruş uyarısı hiç çalışmaz. Eğimin kayması yaw kadar
            // hızlı değil (yerçekimi referansı var), dar pencere yetiyor.
            if abs(relPitch) < driftMaxPitch {
                referencePitch = (referencePitch ?? pitch) + relPitch * k
                relPitch = pitch - referencePitch!
            }
        }

        onPose?(Pose(yaw: relYaw, pitch: relPitch, rate: rate))
    }

    /// -180…180 aralığına sar; referansın öbür tarafına geçince 359 gibi
    /// değerler çıkmasın.
    private static func wrap(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    // MARK: CMHeadphoneMotionManagerDelegate

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        // Yeni takışta eski referans anlamsız.
        referenceYaw = nil
        referencePitch = nil
        onAvailabilityChange?(true)
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        lastRaw = nil
        onAvailabilityChange?(false)
    }
}

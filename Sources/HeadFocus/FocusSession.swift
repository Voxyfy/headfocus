import Foundation
import UserNotifications
import AppKit

/// Odak modu: belirli bir süre boyunca ekrana bakılması beklenir. Kafa
/// eşik açısından fazla dönük kalırsa (birkaç saniye tolerans) sayaç durur
/// ve ekran tamamen bulanır; geri dönünce kaldığı yerden sürer.
///
/// Süre bitince bildirim ve ses. Kayıt tutulmuyor; önce fikrin işe yarayıp
/// yaramadığı görülecek.
final class FocusSession {
    enum State { case idle, running, paused, finished }

    var state: State = .idle { didSet { onChange?() } }
    var onChange: (() -> Void)?

    private(set) var remaining: TimeInterval = 0
    private(set) var total: TimeInterval = 0
    private var ticker: Timer?
    private var awaySince: Date?

    /// Bu kadar saniye dönük kalınca "uzaklaştı" sayılır; kısa bakışlarda
    /// ekranı bulandırmak sinir bozucu.
    var awayTolerance: TimeInterval = 2.5

    func start(minutes: Int) {
        total = TimeInterval(minutes * 60)
        remaining = total
        awaySince = nil
        state = .running
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        awaySince = nil
        state = .idle
    }

    /// Her kafa örneğinde çağrılır. `away` eşik dışında olma durumu.
    func update(away: Bool) {
        guard state == .running || state == .paused else { return }

        if away {
            if awaySince == nil { awaySince = Date() }
            if state == .running, let since = awaySince,
               Date().timeIntervalSince(since) >= awayTolerance {
                state = .paused
            }
        } else {
            awaySince = nil
            if state == .paused { state = .running }
        }
    }

    var remainingLabel: String {
        let m = Int(remaining) / 60
        let s = Int(remaining) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func tick() {
        guard state == .running else { return }
        remaining -= 1
        onChange?()
        if remaining <= 0 {
            ticker?.invalidate()
            ticker = nil
            state = .finished
            notifyFinished()
        }
    }

    private func notifyFinished() {
        NSSound(named: "Glass")?.play()
        let content = UNMutableNotificationContent()
        content.title = "Odak süresi bitti"
        content.body = "\(Int(total) / 60) dakika tamamlandı. Kısa bir mola iyi gelir."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

import Foundation
import UserNotifications
import AppKit

/// Odak modu: belirli bir süre boyunca ekrana bakılması beklenir. Kafa
/// eşik açısından fazla dönük kalırsa (birkaç saniye tolerans) sayaç durur
/// ve ekran tamamen bulanır; geri dönünce kaldığı yerden sürer.
///
/// Mola oturumu aynı sınıf: `isBreak` true ise uzaklaşma sayılmaz, sadece
/// geri sayım. Bitince kayıt `Stats`a yazılır (mola yazılmaz).
final class FocusSession {
    enum State { case idle, running, paused, finished }

    var state: State = .idle { didSet { onChange?() } }
    var onChange: (() -> Void)?
    /// Duraklamadan geri dönüldü (dönüş notu için).
    var onReturn: (() -> Void)?
    /// Oturum bitti; mola teklifi ve bildirim için.
    var onFinished: ((_ wasBreak: Bool) -> Void)?

    private(set) var remaining: TimeInterval = 0
    private(set) var total: TimeInterval = 0
    private(set) var isBreak = false
    /// Kullanıcının oturum başında yazdığı "ne üzerinde çalışıyorum" notu.
    var note: String?

    private var ticker: Timer?
    private var awaySince: Date?
    private var start = Date()
    private var focusedSeconds = 0
    private var awayCount = 0
    private var streak = 0
    private var longestStreak = 0

    /// Bu kadar saniye dönük kalınca "uzaklaştı" sayılır; kısa bakışlarda
    /// ekranı bulandırmak sinir bozucu.
    var awayTolerance: TimeInterval = 2.5

    func start(minutes: Int, isBreak: Bool = false) {
        total = TimeInterval(minutes * 60)
        remaining = total
        self.isBreak = isBreak
        awaySince = nil
        start = Date()
        focusedSeconds = 0
        awayCount = 0
        streak = 0
        longestStreak = 0
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
        if !isBreak, state == .running || state == .paused, focusedSeconds > 0 {
            record(completed: false)
        }
        state = .idle
    }

    /// Her kafa örneğinde çağrılır. `away` eşik dışında olma durumu.
    func update(away: Bool) {
        guard !isBreak, state == .running || state == .paused else { return }

        if away {
            if awaySince == nil { awaySince = Date() }
            if state == .running, let since = awaySince,
               Date().timeIntervalSince(since) >= awayTolerance {
                awayCount += 1
                streak = 0
                state = .paused
            }
        } else {
            awaySince = nil
            if state == .paused {
                state = .running
                onReturn?()
            }
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
        if !isBreak {
            focusedSeconds += 1
            streak += 1
            longestStreak = max(longestStreak, streak)
        }
        onChange?()
        if remaining <= 0 {
            ticker?.invalidate()
            ticker = nil
            state = .finished
            if !isBreak { record(completed: true) }
            notifyFinished()
            onFinished?(isBreak)
        }
    }

    private func record(completed: Bool) {
        Stats.shared.add(FocusRecord(
            start: start,
            plannedSeconds: Int(total),
            focusedSeconds: focusedSeconds,
            awayCount: awayCount,
            longestStreakSeconds: longestStreak,
            completed: completed
        ))
    }

    private func notifyFinished() {
        NSSound(named: "Glass")?.play()
        let content = UNMutableNotificationContent()
        content.title = isBreak ? "Mola bitti" : "Odak süresi bitti"
        content.body = isBreak
            ? "Hazırsan yeni bir odak oturumu başlat."
            : "\(Int(total) / 60) dakika tamamlandı. Kısa bir mola iyi gelir."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

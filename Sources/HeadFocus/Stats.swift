import AppKit
import Foundation

/// Odak istatistikleri ve dikkat ısı haritası. JSON dosyası, Application
/// Support altında. Küçük veri, veritabanına gerek yok.
struct FocusRecord: Codable {
    var start: Date
    var plannedSeconds: Int
    var focusedSeconds: Int
    var awayCount: Int
    var longestStreakSeconds: Int
    var completed: Bool
}

final class Stats {
    static let shared = Stats()

    private(set) var records: [FocusRecord] = []
    /// Gün (yyyy-MM-dd) → 9×5 hücre sayaçları (ekranın hangi bölgesine bakıldı).
    private(set) var heat: [String: [Int]] = [:]

    static let heatColumns = 9
    static let heatRows = 5

    private let url: URL
    private var dirty = false
    private var saveTimer: Timer?

    private struct File: Codable {
        var records: [FocusRecord]
        var heat: [String: [Int]]
    }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeadFocus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("stats.json")
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            records = file.records
            heat = file.heat
        }
        // Isı haritası saniyede birkaç kez güncelleniyor; dosyaya 30 sn'de bir.
        saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.flush() }
    }

    func add(_ record: FocusRecord) {
        records.append(record)
        dirty = true
        flush()
    }

    /// Bakılan açıyı ekran bölgesine çevirip sayar. ±30° yatay, ±20° dikey
    /// aralığı ızgaraya yayılıyor; dışı kenar hücrelere biner.
    func recordGaze(yaw: Double, pitch: Double) {
        let key = Self.dayKey(Date())
        var cells = heat[key] ?? Array(repeating: 0, count: Self.heatColumns * Self.heatRows)
        // yaw pozitif = sol; ekranda sol sütun 0.
        let cx = Int(((-yaw + 30) / 60 * Double(Self.heatColumns)).rounded(.down))
        let cy = Int(((-pitch + 20) / 40 * Double(Self.heatRows)).rounded(.down))
        let x = max(0, min(Self.heatColumns - 1, cx))
        let y = max(0, min(Self.heatRows - 1, cy))
        cells[y * Self.heatColumns + x] += 1
        heat[key] = cells
        dirty = true
    }

    func todayFocusedSeconds() -> Int {
        let key = Self.dayKey(Date())
        return records.filter { Self.dayKey($0.start) == key }.reduce(0) { $0 + $1.focusedSeconds }
    }

    func todayAwayCount() -> Int {
        let key = Self.dayKey(Date())
        return records.filter { Self.dayKey($0.start) == key }.reduce(0) { $0 + $1.awayCount }
    }

    /// Son 7 gün, eskiden yeniye: (gün etiketi, odak dakikası).
    func lastWeek() -> [(String, Int)] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "tr_TR")
        fmt.dateFormat = "EEE"
        return (0..<7).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: Date())!
            let key = Self.dayKey(day)
            let seconds = records.filter { Self.dayKey($0.start) == key }.reduce(0) { $0 + $1.focusedSeconds }
            return (fmt.string(from: day), seconds / 60)
        }
    }

    func todayHeat() -> [Int] {
        heat[Self.dayKey(Date())] ?? Array(repeating: 0, count: Self.heatColumns * Self.heatRows)
    }

    private func flush() {
        guard dirty else { return }
        dirty = false
        // 90 günden eski ısı verisi silinir; kayıtlar kalır (küçük).
        let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -90, to: Date())!)
        heat = heat.filter { $0.key >= cutoff }
        if let data = try? JSONEncoder().encode(File(records: records, heat: heat)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func dayKey(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}

/// İstatistik penceresi: haftalık çubuk grafik + bugünün ısı haritası.
final class StatsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "HeadFocus · İstatistikler"
        window.contentView = StatsView(frame: window.contentView!.bounds)
        window.center()
        self.init(window: window)
    }

    func refresh() { window?.contentView?.needsDisplay = true }
}

final class StatsView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let stats = Stats.shared
        let title = NSAttributedString(string: "Son 7 gün · odak dakikası", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        title.draw(at: NSPoint(x: 24, y: 18))

        let today = stats.todayFocusedSeconds() / 60
        let summary = NSAttributedString(string: "Bugün \(today) dk odak · \(stats.todayAwayCount()) kez uzaklaşma", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        summary.draw(at: NSPoint(x: 24, y: 38))

        // Çubuklar
        let week = stats.lastWeek()
        let maxMinutes = max(30, week.map(\.1).max() ?? 0)
        let chart = NSRect(x: 24, y: 64, width: bounds.width - 48, height: 150)
        let slot = chart.width / CGFloat(week.count)
        for (i, (label, minutes)) in week.enumerated() {
            let h = chart.height * CGFloat(minutes) / CGFloat(maxMinutes)
            let bar = NSRect(x: chart.minX + slot * CGFloat(i) + slot * 0.2,
                             y: chart.maxY - h, width: slot * 0.6, height: h)
            (i == week.count - 1 ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.55)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            let size = text.size()
            text.draw(at: NSPoint(x: bar.midX - size.width / 2, y: chart.maxY + 6))
            if minutes > 0 {
                let value = NSAttributedString(string: "\(minutes)", attributes: [
                    .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.labelColor])
                let vs = value.size()
                value.draw(at: NSPoint(x: bar.midX - vs.width / 2, y: bar.minY - 14))
            }
        }

        // Isı haritası
        let heatTitle = NSAttributedString(string: "Bugün ekranın neresine baktın", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        heatTitle.draw(at: NSPoint(x: 24, y: 250))
        let cells = stats.todayHeat()
        let peak = max(1, cells.max() ?? 1)
        let grid = NSRect(x: 24, y: 276, width: bounds.width - 48, height: 120)
        let cw = grid.width / CGFloat(Stats.heatColumns)
        let ch = grid.height / CGFloat(Stats.heatRows)
        for y in 0..<Stats.heatRows {
            for x in 0..<Stats.heatColumns {
                let v = CGFloat(cells[y * Stats.heatColumns + x]) / CGFloat(peak)
                let rect = NSRect(x: grid.minX + cw * CGFloat(x) + 1, y: grid.minY + ch * CGFloat(y) + 1,
                                  width: cw - 2, height: ch - 2)
                NSColor.controlAccentColor.withAlphaComponent(0.08 + 0.85 * v).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            }
        }
    }
}

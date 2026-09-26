import Foundation

/// Bütün ayarlar UserDefaults'ta; buradan başka yerde anahtar adı geçmiyor.
enum Prefs {
    private static let d = UserDefaults.standard

    private static func bool(_ key: String, default value: Bool) -> Bool {
        d.object(forKey: key) as? Bool ?? value
    }

    static var enabled: Bool { get { bool("enabled", default: true) } set { d.set(newValue, forKey: "enabled") } }
    static var invertSide: Bool { get { bool("invertSide", default: false) } set { d.set(newValue, forKey: "invertSide") } }
    static var startAngle: Double { get { d.object(forKey: "startAngle") as? Double ?? 12 } set { d.set(newValue, forKey: "startAngle") } }
    static var screenSize: Int { get { d.object(forKey: "screenSize") as? Int ?? 1 } set { d.set(newValue, forKey: "screenSize") } }
    static var strength: Int { get { d.object(forKey: "strength") as? Int ?? 2 } set { d.set(newValue, forKey: "strength") } }
    static var glassKind: Int { get { d.object(forKey: "glassKind") as? Int ?? GlassKind.liquid.rawValue } set { d.set(newValue, forKey: "glassKind") } }
    static var blurRadius: Double { get { d.object(forKey: "blurRadius") as? Double ?? 12 } set { d.set(newValue, forKey: "blurRadius") } }

    /// 0 tüm ekranlar, 1 yalnızca ana ekran, 2 imlecin olduğu ekran.
    static var screenMode: Int { get { d.object(forKey: "screenMode") as? Int ?? 0 } set { d.set(newValue, forKey: "screenMode") } }
    static var excludedApps: [String] { get { d.stringArray(forKey: "excludedApps") ?? [] } set { d.set(newValue, forKey: "excludedApps") } }

    static var breakEnabled: Bool { get { bool("breakEnabled", default: false) } set { d.set(newValue, forKey: "breakEnabled") } }
    static var breakMinutes: Int { get { d.object(forKey: "breakMinutes") as? Int ?? 5 } set { d.set(newValue, forKey: "breakMinutes") } }
    static var muteOnAway: Bool { get { bool("muteOnAway", default: false) } set { d.set(newValue, forKey: "muteOnAway") } }
    static var dndOnFocus: Bool { get { bool("dndOnFocus", default: false) } set { d.set(newValue, forKey: "dndOnFocus") } }
    static var returnNote: Bool { get { bool("returnNote", default: true) } set { d.set(newValue, forKey: "returnNote") } }

    static var headScroll: Bool { get { bool("headScroll", default: false) } set { d.set(newValue, forKey: "headScroll") } }
    static var headSpace: Bool { get { bool("headSpace", default: false) } set { d.set(newValue, forKey: "headSpace") } }
    /// 0 kapalı; aksi hâlde dakika.
    static var postureMinutes: Int { get { d.object(forKey: "postureMinutes") as? Int ?? 0 } set { d.set(newValue, forKey: "postureMinutes") } }
    static var heatmap: Bool { get { bool("heatmap", default: true) } set { d.set(newValue, forKey: "heatmap") } }
    static var headMouse: Bool { get { bool("headMouse", default: false) } set { d.set(newValue, forKey: "headMouse") } }
    static var dwellClick: Bool { get { bool("dwellClick", default: false) } set { d.set(newValue, forKey: "dwellClick") } }
}

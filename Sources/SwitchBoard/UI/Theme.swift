import SwiftUI

/// 界面语言：设置里选了就用选的，否则跟随系统首选语言（中文 → 中文，其余 → 英文）
enum Lang {
    nonisolated(unsafe) static var override: String = UserDefaults.standard.string(forKey: "language") ?? "auto"
    static var isZh: Bool {
        switch override {
        case "zh": return true
        case "en": return false
        default: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }
    static var locale: Locale { Locale(identifier: isZh ? "zh_CN" : "en_US") }
}

func L(_ zh: String, _ en: String) -> String { Lang.isZh ? zh : en }

enum Theme {
    static let panelWidth: CGFloat = 380
    /// 当前展示的 provider，主题色随它变化（Claude 橙 / Codex 紫）
    nonisolated(unsafe) static var current: Provider = .claude
    static var accent: Color {
        current == .claude ? Color(red: 0.98, green: 0.45, blue: 0.27) : Color(red: 0.58, green: 0.47, blue: 1.00)
    }
    static var accentDeep: Color {
        current == .claude ? Color(red: 0.78, green: 0.33, blue: 0.30) : Color(red: 0.34, green: 0.36, blue: 0.92)
    }
    // 明确的文字色（系统 .secondary/.tertiary 在磨砂背景上会再被压暗）
    static let text1 = Color.white.opacity(0.96)
    static let text2 = Color.white.opacity(0.78)
    static let text3 = Color.white.opacity(0.58)
    static let good = Color(red: 0.13, green: 0.88, blue: 0.52)
    static let warn = Color(red: 1.00, green: 0.71, blue: 0.10)
    static let bad = Color(red: 1.00, green: 0.33, blue: 0.30)

    static func tint(_ remaining: Double) -> Color {
        remaining > 50 ? good : remaining > 20 ? warn : bad
    }

    static let palette: [(Color, Color)] = [
        (Color(red: 0.36, green: 0.66, blue: 1.00), Color(red: 0.22, green: 0.42, blue: 0.90)),  // 蓝
        (Color(red: 0.22, green: 0.84, blue: 0.74), Color(red: 0.08, green: 0.58, blue: 0.68)),  // 青
        (Color(red: 1.00, green: 0.80, blue: 0.32), Color(red: 0.90, green: 0.55, blue: 0.14)),  // 琥珀
        (Color(red: 0.58, green: 0.86, blue: 0.42), Color(red: 0.24, green: 0.64, blue: 0.40)),  // 草绿
        (Color(red: 0.62, green: 0.70, blue: 0.98), Color(red: 0.38, green: 0.44, blue: 0.82)),  // 雾靛
    ]

    static func avatar(_ key: String) -> (Color, Color) {
        let h = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[h % palette.count]
    }
}

/// "2 小时 31 分后"
func relative(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "—" }
    let s = Int(date.timeIntervalSince(now))
    if s <= 0 { return L("即将", "soon") }
    let m = (s + 59) / 60
    if m < 60 { return L("\(m) 分钟后", "in \(m) min") }
    if m < 1440 { return L("\(m / 60) 小时 \(m % 60) 分后", "in \(m / 60)h \(m % 60)m") }
    return L("\(m / 1440) 天 \((m % 1440) / 60) 小时后", "in \(m / 1440)d \((m % 1440) / 60)h")
}

func clock(_ date: Date?) -> String {
    guard let date else { return "" }
    let f = DateFormatter()
    f.locale = Lang.locale
    f.dateFormat = Calendar.current.isDateInToday(date) ? L("今天 HH:mm", "'Today' HH:mm") : L("M月d日 HH:mm", "MMM d HH:mm")
    return f.string(from: date)
}

/// "4h40m" / "33m" / "2d3h"
func compact(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "—" }
    let m = (max(0, Int(date.timeIntervalSince(now))) + 59) / 60
    if m < 60 { return "\(m)m" }
    if m < 1440 { return "\(m / 60)h\(m % 60)m" }
    return "\(m / 1440)d\((m % 1440) / 60)h"
}

/// 倒计时与重置时刻分开返回，便于分列对齐："48m" + "00:50" / "1d18h" + "10/28 19:00"
func resetParts(_ date: Date?, now: Date = Date()) -> (String, String)? {
    guard let date else { return nil }
    let f = DateFormatter()
    f.locale = Lang.locale
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
    return (compact(date, now: now), f.string(from: date))
}

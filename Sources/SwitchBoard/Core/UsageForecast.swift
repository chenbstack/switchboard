import Foundation

/// 额度采样点：某个时刻的周 / 5 小时剩余%，以及各自所属窗口的重置时间。
/// 数值没变化时只延长最后一个点的时间（t 表示「到 t 为止一直是这个值」），这样相邻两点之间的时长就是精确的。
struct UsagePoint: Codable, Equatable {
    var t: Date
    var w: Double?
    var wr: Date?
    var s: Double? = nil
    var sr: Date? = nil
}

/// 同一服务的整体用量速度（额度单位/小时），分别按过去 1 小时 / 1 天 / 72 小时统计，再加权合成。
/// 某个窗口的采样覆盖不足（不到窗口的 25%，且至少 30 分钟）时不参与，剩下的权重重新归一。
struct DemandRates {
    var hour: Double?
    var day: Double?
    var long: Double?
    /// 合成速度：1 小时 25% + 1 天 55% + 72 小时 20%（偏重近期习惯）
    var blended: Double? {
        let parts = [(hour, 0.25), (day, 0.55), (long, 0.2)].compactMap { r, w in r.map { ($0, w) } }
        let total = parts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        return parts.reduce(0) { $0 + $1.0 * $1.1 } / total
    }
}

/// 使用速度预测：
/// 1. 每次刷新记录每个账号的周额度采样点（保留 72 小时）
/// 2. 把同一服务下所有账号的消耗按「额度单位」汇总，分别算出过去 1 小时 / 1 天 / 72 小时的用量速度，加权合成
///    —— 1 小时反映当下，1 天反映近期习惯，72 小时反映长期平均
///    —— 不同会员级别容量不同：Max 20x 周额度掉 1% ≈ Pro 掉 10%，所以按档位折算
/// 3. 按「周额度先到期的先用」模拟这个速度下各账号到重置时还会剩多少，剩下的就是真正会作废的额度
/// 三个窗口都采样不足时，退回「按时间均匀消耗」的假设。
extension AppModel {
    static let historyWindow: TimeInterval = 72 * 3600
    static let demandWindows: [TimeInterval] = [3600, 24 * 3600, 72 * 3600]

    /// 账号周额度的相对容量（近似值）。Max 20x 的 5 小时额度是 Pro 的 20 倍，但周额度只按 10 倍算
    func capacityWeight(_ a: Account) -> Double {
        let l = a.planLabel.lowercased()
        if a.provider == .claude {
            if l.contains("20x") { return 10 }
            if l.contains("5x") || l.hasPrefix("max") { return 5 }
            return 1                       // Pro / Team / 其他
        }
        return l.hasPrefix("pro") ? 10 : 1 // Codex：ChatGPT Pro 约为 Plus 的 10 倍
    }

    /// 账号 5 小时额度的相对容量（近似值）：Max 20x 是 Pro 的 20 倍
    func sessionWeight(_ a: Account) -> Double {
        let l = a.planLabel.lowercased()
        if a.provider == .claude {
            if l.contains("20x") { return 20 }
            if l.contains("5x") || l.hasPrefix("max") { return 5 }
            return 1
        }
        return l.hasPrefix("pro") ? 10 : 1
    }

    func sameWindow(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return abs(x.timeIntervalSince(y)) < 600
        default: return false
        }
    }

    /// 刷新完额度后调用：追加采样点、清理过期数据、重算用量速度
    func recordHistory() {
        let now = Date()
        for a in accounts where a.api == nil {
            guard status[a.id] == nil, let u = usage[a.id], u.weekly != nil || u.session != nil else { continue }
            var pts = history[a.id] ?? []
            let new = UsagePoint(t: u.fetchedAt, w: u.weekly?.remaining, wr: u.weekly?.resetsAt, s: u.session?.remaining, sr: u.session?.resetsAt)
            func same(_ p: UsagePoint) -> Bool {
                func eq(_ x: Double?, _ y: Double?) -> Bool { x == nil && y == nil || (x != nil && y != nil && abs(x! - y!) < 0.05) }
                return eq(p.w, new.w) && eq(p.s, new.s) && sameWindow(p.wr, new.wr) && sameWindow(p.sr, new.sr)
            }
            if let last = pts.last {
                if last.t >= new.t { continue }
                if same(last) {
                    // 没变化：延长最后一个点；前一个点也相同时直接顺延，否则补一个点标出「从这里开始没变」
                    if pts.count >= 2, same(pts[pts.count - 2]) { pts[pts.count - 1].t = new.t } else { pts.append(new) }
                    history[a.id] = pts
                    continue
                }
            }
            pts.append(new)
            history[a.id] = pts
        }
        let ids = Set(accounts.map(\.id))
        for k in Array(history.keys) {
            if !ids.contains(k) { history[k] = nil; continue }
            history[k] = history[k]?.filter { now.timeIntervalSince($0.t) <= Self.historyWindow }
        }
        recomputeDemand()
        AccountStore.saveHistory(history)
    }

    /// 每个服务的整体用量速度（额度单位/小时）；采样不足则没有
    func recomputeDemand() {
        let now = Date()
        var detail: [Provider: DemandRates] = [:]
        for p in Provider.allCases {
            let series = accounts.filter { $0.provider == p && $0.api == nil }.map { a in
                (capacityWeight(a), (history[a.id] ?? []).sorted { $0.t < $1.t })
            }
            guard let first = series.compactMap({ $0.1.first?.t }).min() else { continue }
            func rate(_ window: TimeInterval) -> Double? {
                let start = now.addingTimeInterval(-window)
                let coverage = now.timeIntervalSince(max(first, start))
                guard coverage >= max(1800, window * 0.25) else { return nil }
                var drop = 0.0
                for (weight, pts) in series {
                    // 周窗口重置时额度会往上跳，被 sameWindow 过滤掉
                    for (x, y) in zip(pts, pts.dropFirst()) where y.t >= start && sameWindow(x.wr, y.wr) {
                        guard let xw = x.w, let yw = y.w, yw < xw else { continue }
                        drop += (xw - yw) * weight
                    }
                }
                return drop / (coverage / 3600)
            }
            let r = DemandRates(hour: rate(Self.demandWindows[0]), day: rate(Self.demandWindows[1]), long: rate(Self.demandWindows[2]))
            if r.blended != nil { detail[p] = r }
        }
        demandDetail = detail
        demandRate = detail.compactMapValues(\.blended)
    }

    /// 预测各账号（%）到周额度重置时还会剩多少 = 会作废的额度。没有速度数据返回 nil。
    /// 模拟：周额度先到期的先用；某个账号到期前用不完的需求，溢出到后面到期的账号。
    func wasteForecast(_ p: Provider) -> [String: Double]? {
        guard let d = demandRate[p] else { return nil }
        let now = Date()
        let items = accounts.compactMap { a -> (Account, Double, Double)? in
            guard a.provider == p, a.api == nil, status[a.id] == nil,
                  let w = usage[a.id]?.weekly, let r = w.resetsAt else { return nil }
            return (a, max(0, r.timeIntervalSince(now)) / 3600, w.remaining * capacityWeight(a))
        }.sorted { $0.1 < $1.1 }
        var out: [String: Double] = [:]
        var carry = 0.0, prev = 0.0
        for (a, hours, units) in items {
            let avail = carry + d * (hours - prev)   // 到这个账号到期前，还没被更早到期的账号消化掉的需求
            let used = min(units, avail)
            out[a.id] = (units - used) / capacityWeight(a)
            carry = avail - used
            prev = hours
        }
        return out
    }
}

/// 界面展示用的预测结果
struct ForecastLine {
    let text: String
    /// 预计作废量达到「快作废」阈值：界面用主题色强调
    let highlight: Bool
    /// 悬浮提示：用量速度明细
    let help: String
}

extension AppModel {
    /// 账号卡片上的预测提示；没有预测数据（采样不足 / API 账号 / 没有周额度）时返回 nil
    func forecastLine(_ a: Account) -> ForecastLine? {
        guard a.api == nil, status[a.id] == nil, let w = usage[a.id]?.weekly,
              let raw = wasteForecast(a.provider)?[a.id], let rates = demandDetail[a.provider] else { return nil }
        let waste = min(raw, w.remaining)
        let text = waste >= 1
            ? L("周额度预计作废 \(Int(waste.rounded()))%", "~\(Int(waste.rounded()))% of weekly quota expected to expire")
            : L("周额度预计能用完", "Weekly quota expected to be used up")
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f%%/h", $0) } ?? "—" }
        let help = L("用量速度（折算为 Pro 周额度）：近 1 小时 \(f(rates.hour)) · 近 1 天 \(f(rates.day)) · 近 72 小时 \(f(rates.long))；加权后 \(f(rates.blended))",
                     "Usage speed (as Pro weekly quota): last hour \(f(rates.hour)) · last day \(f(rates.day)) · last 72h \(f(rates.long)); blended \(f(rates.blended))")
        return ForecastLine(text: text, highlight: waste >= Double(expiringThreshold), help: help)
    }
}

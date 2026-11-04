import Foundation

/// 5 小时额度的「活跃消耗速度」与耗尽预测，以及整个账号池周额度够不够用的预测。
extension AppModel {
    /// 只看最近这么久的活跃消耗
    private static let burnWindow: TimeInterval = 90 * 60
    /// 预计多少分钟内会用完，就提前切走
    static let exhaustLeadMinutes = 20.0

    /// 账号 5 小时额度最近的活跃消耗速度（%/小时）和最近一次消耗的时间。
    /// 只统计「确实在掉」的区间（掉了多少 ÷ 这段区间多长），空闲时间不稀释速度；最近没消耗过则没有。
    func burn(_ a: Account) -> (rate: Double, lastDrop: Date)? {
        let now = Date()
        let pts = (history[a.id] ?? []).filter { now.timeIntervalSince($0.t) <= Self.burnWindow }.sorted { $0.t < $1.t }
        var drop = 0.0, secs = 0.0
        var last: Date?
        for (x, y) in zip(pts, pts.dropFirst()) {
            guard let xs = x.s, let ys = y.s, ys < xs, sameWindow(x.sr, y.sr) else { continue }
            drop += xs - ys
            secs += y.t.timeIntervalSince(x.t)
            last = y.t
        }
        guard drop > 0, secs > 0, let last else { return nil }
        return (drop / (secs / 3600), last)
    }

    /// 正在被使用：最近一次消耗离现在不久（至少 15 分钟，或两个刷新周期）
    func burnIfActive(_ a: Account) -> Double? {
        guard let b = burn(a), Date().timeIntervalSince(b.lastDrop) <= max(900, Double(refreshInterval) * 2) else { return nil }
        return b.rate
    }

    /// 按当前活跃速度，5 小时额度还要多少分钟用完；没在用 / 用不完（重置先到）返回 nil
    func minutesToExhaust(_ a: Account) -> Double? {
        guard let s = usage[a.id]?.session, let rate = burnIfActive(a) else { return nil }
        let mins = s.remaining / rate * 60
        if let r = s.resetsAt, r.timeIntervalSinceNow / 60 <= mins { return nil }
        return mins
    }

    /// 额度见底时要不要等它重置：5 小时额度是瓶颈且有活跃速度时，看剩下的撑不撑得到重置；否则退回「15 分钟内重置就等」
    func shouldWaitForReset(_ a: Account) -> Bool {
        guard let u = usage[a.id] else { return false }
        if let s = u.session, let r = s.resetsAt, s.remaining <= (u.weekly?.remaining ?? 101), let rate = burnIfActive(a) {
            return s.remaining / rate * 3600 >= r.timeIntervalSinceNow
        }
        return resetsSoon(a)
    }

    /// 整个服务的活跃消耗速度（5 小时额度单位/小时，按档位折算）：用于判断候选账号能撑多久
    func activeRate(_ p: Provider) -> Double? {
        var units = 0.0
        var n = 0
        for a in accounts where a.provider == p && a.api == nil {
            if let r = burn(a)?.rate { units += r * sessionWeight(a); n += 1 }
        }
        return n > 0 ? units / Double(n) : nil
    }

    /// 候选账号的 5 小时额度按活跃速度还能撑多少小时；没有速度数据返回 nil
    func lastsHours(_ a: Account, rate: Double?) -> Double? {
        guard let rate, rate > 0, let s = usage[a.id]?.session else { return nil }
        let rem: Double = {
            if let r = s.resetsAt, r.timeIntervalSinceNow <= Self.predictHorizon { return 100 }
            return s.remaining
        }()
        return rem * sessionWeight(a) / rate
    }
}

/// 周额度池的预测结果
struct PoolForecast {
    /// 约多少小时后所有账号的周额度同时用完
    let firstShortHours: Double
    /// 未来 7 天里累计约有多少小时没有额度可用
    let unmetHours: Double
    /// 缺额之后，最早多少小时后有账号重置
    let nextSupplyHours: Double?
}

extension AppModel {
    /// 按当前用量速度推演未来 7 天：每个账号周额度重置时补满，先到期的先消耗；
    /// 如果某个时段所有账号都空了、需求还在，就是「总额度不够用」。没有速度数据 / 不缺额度返回 nil。
    func poolForecast(_ p: Provider) -> PoolForecast? {
        guard let d = demandRate[p], d > 0 else { return nil }
        let items = accounts.compactMap { a -> (Double, Double, Double)? in
            guard a.provider == p, a.api == nil, status[a.id] == nil,
                  let w = usage[a.id]?.weekly, let r = w.resetsAt else { return nil }
            let weight = capacityWeight(a)
            return (w.remaining * weight, 100 * weight, max(0, r.timeIntervalSinceNow) / 3600)
        }
        guard !items.isEmpty else { return nil }
        var rem = items.map(\.0)
        let full = items.map(\.1)
        var reset = items.map(\.2)
        let step = 0.5, horizon = 168.0
        var t = 0.0, unmet = 0.0
        var first: Double?, next: Double?
        while t < horizon {
            t += step
            for i in rem.indices where reset[i] <= t {
                rem[i] = full[i]
                reset[i] += 168
                if first != nil, next == nil { next = t }
            }
            var need = d * step
            for i in rem.indices.sorted(by: { reset[$0] < reset[$1] }) where need > 0 {
                let take = min(rem[i], need)
                rem[i] -= take
                need -= take
            }
            if need > 1e-9 {
                unmet += need / d
                if first == nil { first = t }
            }
        }
        guard let first, unmet >= 1 else { return nil }
        return PoolForecast(firstShortHours: first, unmetHours: unmet, nextSupplyHours: next)
    }
}

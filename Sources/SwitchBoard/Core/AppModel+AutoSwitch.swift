import Foundation
import UserNotifications

/// 自动切换账号：当前账号额度快用完时，按优先级切到最合适的账号。
///
/// 优先级分数（越高越先用）= 2 × 周额度「没用完的部分」 + 0.5 × 可用额度
///   目标是少浪费额度：快作废的额度权重最高；可用额度只作次要因素（保证账号现在用得动）
///   可用额度 = min(5 小时剩余%, 本周剩余%) —— 谁先见底谁决定账号现在还能用多少
///   没用完的部分 = 本周剩余% − 本周窗口剩余时间占比×100（假设均匀消耗，超出的就是快要作废的额度）
///     例：剩 70% 但 6 小时后重置 → 多出约 66 分；剩 90% 但还有 6 天重置 → 只多出约 1 分
/// 不参与：需要重新登录 / 刷新出错 / 没有额度数据 / 任一窗口已低于阈值 / 自定义 API 账号。
enum AutoSwitchReason: Equatable {
    case low(from: String, remaining: Int)
    /// weeklyLeft：候选账号周额度剩余%；hours：距周额度重置还有多少小时
    case expiring(from: String, weeklyLeft: Int, hours: Int)
    /// 按当前速度，5 小时额度约 minutes 分钟后用完
    case exhausting(from: String, minutes: Int)
    var kind: String {
        switch self {
        case .low: return "low"
        case .exhausting: return "exhausting"
        case .expiring: return "expiring"
        }
    }
}

/// 待用户确认的切换建议
struct SwitchSuggestion: Equatable {
    let targetID: String
    let targetName: String
    let provider: Provider
    let fromID: String
    let reason: AutoSwitchReason
    var key: String { targetID + ":" + reason.kind }
}

extension AppModel {
    /// 额度低于这个百分比就触发切换
    static let autoSwitchThresholds = [1, 5, 10, 15, 20]
    /// 候选账号的可用额度至少要比当前账号高出这么多，避免来回抖动
    private static let minGain = 15.0
    /// 两次自动切换之间的最短间隔
    private static let cooldown: TimeInterval = 10 * 60
    /// 当前账号见底的那个窗口如果这么快就重置，就等它重置，不切
    private static let waitForReset: TimeInterval = 15 * 60
    private static let weekHours = 168.0
    /// 候选账号可用额度达到这个值才算「够用」，够用的账号一律排在不够用的前面
    private static let decentQuota = 30.0
    /// 主动切换：候选账号至少有这么多「快作废」的周额度（%）
    static let expiringOptions = [5, 10, 15, 25, 35, 50]
    private var expiringMin: Double { Double(expiringThreshold) }
    /// 主动切换：候选账号现在可用额度至少这么多（%）
    private static let expiringUsable = 25.0

    /// 重置预测：窗口在这么久内就会重置的，排序时按「已重置」(100%) 计算
    static let predictHorizon: TimeInterval = 60 * 60

    /// 窗口剩余额度；projected 时，马上重置的窗口按重置后（100%）算
    private func remaining(_ m: Meter?, projected: Bool) -> Double? {
        guard let m else { return nil }
        if projected, let r = m.resetsAt, r.timeIntervalSinceNow <= Self.predictHorizon { return 100 }
        return m.remaining
    }

    /// 账号可用额度（%）；没有数据返回 nil。projected = true 时计入马上到来的重置
    func effectiveRemaining(_ a: Account, projected: Bool = false) -> Double? {
        guard a.api == nil, status[a.id] == nil, let u = usage[a.id] else { return nil }
        return [remaining(u.session, projected: projected), remaining(u.weekly, projected: projected)].compactMap { $0 }.min()
    }

    /// 周额度里「按均匀消耗算用不完」的部分（%）；越大越应该优先用。
    /// 周额度马上重置时（projected），重置后是满额新窗口，没有「快作废」的部分
    func weeklySurplus(_ a: Account, projected: Bool = false) -> Double {
        guard let w = usage[a.id]?.weekly, let reset = w.resetsAt else { return 0 }
        if projected, reset.timeIntervalSinceNow <= Self.predictHorizon { return 0 }
        // 有用量速度数据：用预测的「到期时还会剩多少」；否则按时间均匀消耗估算
        if let f = wasteForecast(a.provider)?[a.id] { return min(f, w.remaining) }
        let hours = max(0, reset.timeIntervalSinceNow / 3600)
        let timeLeft = min(1, hours / Self.weekHours) * 100
        return max(0, w.remaining - timeLeft)
    }

    /// 优先级分数（含重置预测）；预测后仍不可用返回 nil
    func priorityScore(_ a: Account) -> Double? {
        guard let eff = effectiveRemaining(a, projected: true), eff > Double(autoSwitchThreshold) else { return nil }
        return 2 * weeklySurplus(a, projected: true) + 0.5 * eff
    }

    /// 周额度还有多久重置（秒）；没有重置时间返回 nil
    func weeklyResetIn(_ a: Account) -> TimeInterval? {
        usage[a.id]?.weekly?.resetsAt.map { max(0, $0.timeIntervalSinceNow) }
    }

    /// 账号现在就能用（不靠预测）
    func usableNow(_ a: Account) -> Bool {
        (effectiveRemaining(a) ?? 0) > Double(autoSwitchThreshold)
    }

    /// 现在用不了、但马上重置：返回还有多少分钟（界面提示用）
    func minutesToReset(_ a: Account) -> Int? {
        guard !usableNow(a), let u = usage[a.id] else { return nil }
        let soon = [u.session, u.weekly].compactMap { $0 }
            .filter { $0.remaining <= Double(autoSwitchThreshold) }.compactMap(\.resetsAt).map { $0.timeIntervalSinceNow }
        guard let t = soon.max() else { return nil }
        return max(1, Int((t / 60).rounded(.up)))
    }

    /// 预计什么时候会触发切换（按当前账号 5 小时额度的活跃速度，到「额度低于阈值」或「快用完」先到者）。
    /// 时间以额度的获取时刻为起点算出，之后随着时间流逝倒数；没在使用 / 没有速度数据 / 会先重置则没有
    func switchDate(_ cur: Account) -> Date? {
        guard let u = usage[cur.id], let s = u.session, let rate = burnIfActive(cur), rate > 0 else { return nil }
        var t = max(0, (s.remaining - Double(autoSwitchThreshold)) / rate * 60)
        if let ex = minutesToExhaust(cur) { t = min(t, max(0, ex - Self.exhaustLeadMinutes)) }
        let at = u.fetchedAt.addingTimeInterval(t * 60)
        if let r = s.resetsAt, r <= at { return nil }
        return at
    }

    /// 账号见底的那个窗口是否马上就要重置（马上重置就不必切走）
    func resetsSoon(_ a: Account) -> Bool {
        guard let u = usage[a.id] else { return false }
        let metered = [u.session, u.weekly].compactMap { $0 }
        guard let low = metered.min(by: { $0.remaining < $1.remaining }), let r = low.resetsAt else { return false }
        return r.timeIntervalSinceNow <= Self.waitForReset
    }

    /// 同 provider 下，除当前账号外优先级最高的账号。
    /// usableNow = true：只要现在就能用的（真正切换用）；false：含马上重置的账号（排序展示用）
    func bestCandidate(for p: Provider, usableNow only: Bool = false) -> Account? {
        let pool = accounts.filter { $0.provider == p && !isActive($0) && (!only || usableNow($0)) }
        // 账号池整体有快作废的额度（预测用不完）时，谁先到期谁先用：把额度花在最早到期的账号上，
        // 溢出的浪费就落在最晚到期的账号身上，总浪费最少。不能只给「自己有溢出」的账号加分，
        // 否则刚重置、周额度最晚到期的账号会因为「预计用不完」排在快到期的账号前面。
        let poolHasSurplus = pool.contains { weeklySurplus($0, projected: true) >= expiringMin }
        return pool
            .compactMap { a -> (Account, [Double])? in
                guard let score = priorityScore(a) else { return nil }
                // 够用：有活跃速度数据时，5 小时额度至少能撑 1 小时；否则可用额度 ≥ 30%
                let decent = lastsHours(a, rate: activeRate(p)).map { $0 >= 1 } ?? ((effectiveRemaining(a, projected: true) ?? 0) >= Self.decentQuota)
                // 排序依据依次为：够用 > 有快作废额度 > （有快作废额度的）周额度先到期的优先 / 其余按分数
                let expiring = poolHasSurplus && (effectiveRemaining(a, projected: true) ?? 0) >= Self.expiringUsable
                let deadline = -(weeklyResetIn(a) ?? .greatestFiniteMagnitude)
                return (a, [decent ? 1 : 0, expiring ? 1 : 0, expiring ? deadline : score])
            }
            .max { $0.1.lexicographicallyPrecedes($1.1) }?.0
    }

    /// 界面上标「下一个」的账号：开启建议或自动切换时显示
    var autoNextID: String? {
        guard autoSwitch || suggestSwitch, let cur = activeAccount, cur.api == nil else { return nil }
        return bestCandidate(for: provider)?.id
    }

    /// 现在是否该切：返回要切到的账号和原因（每个 provider 独立判断，取第一个满足的）
    ///  1. 当前账号额度快用完 → 切到优先级最高的账号
    ///  2. 当前账号额度还够，但别的账号周额度快重置且还有很多没用 → 切过去优先消耗（不然就作废了）
    func pendingSwitch() -> (Account, AutoSwitchReason, Account)? {
        for p in Provider.allCases {
            // 当前在用自定义 API / 没有在用的订阅账号：不干预
            guard let cur = accounts.first(where: { $0.provider == p && isActive($0) }), cur.api == nil,
                  let curEff = effectiveRemaining(cur), let next = bestCandidate(for: p, usableNow: true),
                  let eff = effectiveRemaining(next, projected: true) else { continue }
            // 额度见底，或按当前速度很快就会用完
            let isLow = curEff <= Double(autoSwitchThreshold)
            let exhaust = minutesToExhaust(cur).flatMap { $0 <= Self.exhaustLeadMinutes ? $0 : nil }
            if isLow || exhaust != nil {
                guard !shouldWaitForReset(cur), eff >= curEff + Self.minGain else { continue }
                if isLow { return (next, .low(from: cur.name, remaining: Int(curEff.rounded())), cur) }
                return (next, .exhausting(from: cur.name, minutes: max(1, Int((exhaust ?? 0).rounded()))), cur)
            }
            // 候选有快作废额度且现在用得动；当前账号自己也有快作废额度时，只有候选的周额度比当前账号先到期才切
            // （始终先用最先到期的，所以不会来回切）
            let curHasSurplus = weeklySurplus(cur) >= expiringMin
            let nextFirst = (weeklyResetIn(next) ?? .greatestFiniteMagnitude) < (weeklyResetIn(cur) ?? .greatestFiniteMagnitude)
            if !curHasSurplus || nextFirst, weeklySurplus(next) >= expiringMin, (effectiveRemaining(next) ?? 0) >= Self.expiringUsable,
               let w = usage[next.id]?.weekly, let reset = w.resetsAt {
                return (next, .expiring(from: cur.name, weeklyLeft: Int(w.remaining.rounded()),
                                        hours: max(1, Int((reset.timeIntervalSinceNow / 3600).rounded()))), cur)
            }
        }
        return nil
    }

    /// 刷新完额度后调用：自动切换开着就直接切；否则建议开着就弹提示等用户确认
    func autoSwitchIfNeeded() {
        guard (autoSwitch && !demo) || suggestSwitch, switching == nil else { suggestion = nil; return }
        if let t = lastAutoSwitch, Date().timeIntervalSince(t) < Self.cooldown { suggestion = nil; return }
        guard let (next, reason, cur) = pendingSwitch() else { suggestion = nil; return }
        if autoSwitch && !demo {
            suggestion = nil
            lastAutoSwitch = Date()
            switchTo(next, auto: reason)
            return
        }
        let s = SwitchSuggestion(targetID: next.id, targetName: next.name, provider: next.provider, fromID: cur.id, reason: reason)
        if let until = snoozed[s.key], until > Date() { suggestion = nil; return }
        if suggestion != s { suggestion = s }
    }

    func acceptSuggestion() {
        guard let s = suggestion, let acc = accounts.first(where: { $0.id == s.targetID }) else { suggestion = nil; return }
        suggestion = nil
        lastAutoSwitch = Date()
        switchTo(acc)
    }

    /// 忽略：1 小时内不再为同一个账号、同一种原因提示
    func dismissSuggestion() {
        guard let s = suggestion else { return }
        snoozed[s.key] = Date().addingTimeInterval(3600)
        suggestion = nil
    }

    func reasonText(_ reason: AutoSwitchReason, to: String) -> String {
        switch reason {
        case .low(let from, let r):
            return L("\(from) 的额度只剩 \(r)%，\(to) 还有更多可用。", "\(from) is down to \(r)% quota; \(to) has more left.")
        case .exhausting(let from, let m):
            return L("按当前速度，\(from) 的 5 小时额度约 \(m) 分钟后用完，\(to) 还有更多可用。",
                     "At the current pace \(from)'s 5-hour quota runs out in ~\(m) min; \(to) has more left.")
        case .expiring(let from, let left, let h):
            let t = h >= 48 ? L("\(h / 24) 天", "\(h / 24) days") : L("\(h) 小时", "\(h)h")
            return L("\(to) 的周额度还剩 \(left)%，\(t)后就重置，不用就浪费了。\(from) 目前额度仍够用。",
                     "\(to) still has \(left)% weekly quota but resets in \(t); it will go to waste otherwise. \(from) still has enough.")
        }
    }

    func notifyAutoSwitch(_ reason: AutoSwitchReason, to: String) {
        let title = L("已自动切换到 \(to)", "Auto-switched to \(to)")
        let body = reasonText(reason, to: to) + " " + L("新会话立即生效，已打开的会话需重启。", "New sessions use it right away; restart open ones.")
        say(title + " · " + body)
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// 打开开关时申请通知权限
    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

import Foundation

extension AppModel {
    /// 后台增量扫描本地会话日志（首次会读最近 8 天，之后只读新增部分）
    func scanTokens() {
        guard !demo, !tokenScanning else { return }
        tokenScanning = true
        var snapshot = tokenStats
        let tl = timeline
        Task.detached(priority: .utility) {
            TokenScanner.scan(&snapshot, timeline: tl)
            TokenStatsStore.save(snapshot)
            await MainActor.run { [snapshot] in
                self.tokenStats = snapshot
                self.tokenScanning = false
                self.recomputeDemand()
            }
        }
    }

    /// 记录当前账号的变化（演示模式不记）。晚于登录状态读取、早于下一次扫描，所以新产生的日志总能归到正确的账号
    func recordTimeline(_ p: Provider, _ id: LiveIdentity?) {
        guard !demo else { return }
        let before = timeline.entries[p.rawValue]?.count
        timeline.record(p, uuid: id?.uuid)
        if timeline.entries[p.rawValue]?.count != before { timeline.save() }
    }

    func openUsage() {
        scanTokens()
        route = .usage
    }

    /// 演示数据：近 3 天、每小时一桶
    func seedDemoTokens() {
        var s = TokenStats()
        let now = Date()
        let base = Int(now.timeIntervalSince1970 / 3600) * 3600
        func put(_ p: Provider, _ m: String, _ h: Int, _ i: Int, _ o: Int, _ cr: Int, _ cw: Int, _ rea: Int = 0) {
            var b = TokenBucket(input: i, output: o, cacheRead: cr, cacheWrite: cw, reasoning: rea, messages: max(1, (i + o) / 9000))
            b.cost = TokenPrice.cost(m, input: i, output: o, cacheRead: cr, write5m: 0, write1h: cw)
            b.speedTokens = o; b.speedSecs = Double(o) / (m.contains("haiku") ? 150 : m.contains("sonnet") ? 74 : 56)
            s.buckets["\(p.rawValue)|demo|\(m)|\(base - h * 3600)", default: TokenBucket()].add(b)
        }
        for h in 0..<72 where h % 3 != 2 {
            put(.claude, "claude-opus-5-5", h, 1_200 + h * 7, 60_000, 6_800_000, 480_000)
            put(.claude, "claude-sonnet-5-5", h, 800, 25_000, 2_600_000, 160_000)
            if h % 4 == 0 { put(.claude, "claude-haiku-5-5", h, 400, 9_000, 600_000, 40_000) }
            put(.codex, "gpt-5.5", h, 90_000, 14_000, 1_900_000, 0, 6_000)
        }
        tokenStats = s
    }
}

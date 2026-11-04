import Foundation

/// 一个小时内某 provider / 模型 的 token 累计
struct TokenBucket: Codable, Equatable {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, reasoning = 0, messages = 0
    var cost = 0.0
    var speedTokens = 0, speedSecs = 0.0

    mutating func add(_ o: TokenBucket) {
        input += o.input; output += o.output; cacheRead += o.cacheRead; cacheWrite += o.cacheWrite
        reasoning += o.reasoning; messages += o.messages; cost += o.cost
        speedTokens += o.speedTokens; speedSecs += o.speedSecs
    }
    var total: Int { input + output + cacheRead + cacheWrite + reasoning }
    /// 输入侧的缓存命中率
    var hitRate: Double? {
        let d = input + cacheRead + cacheWrite
        return d > 0 ? Double(cacheRead) / Double(d) : nil
    }
    /// 输出速度下限（tok/s）
    var tokPerSec: Double? { speedSecs > 0 ? Double(speedTokens) / speedSecs : nil }
}

/// 每个模型每百万 token 的价格（美元）。只收录确认过的；没收录的模型不算费用
enum TokenPrice {
    static func rates(_ model: String) -> (input: Double, output: Double)? {
        let m = model.lowercased()
        guard m.hasPrefix("claude") else { return nil }
        if m.contains("fable") || m.contains("mythos") { return (10, 50) }
        if m.contains("opus-5-5") { return (4, 20) }
        if m.contains("opus") { return (5, 25) }
        if m.contains("sonnet-5") { return (2, 10) }
        if m.contains("sonnet") { return (3, 15) }
        if m.contains("haiku-5") { return (0.1, 0.5) }
        if m.contains("haiku") { return (1, 5) }
        return nil
    }

    /// 缓存读 0.1×，5 分钟缓存写 1.25×，1 小时缓存写 2×
    static func cost(_ model: String, input: Int, output: Int, cacheRead: Int, write5m: Int, write1h: Int) -> Double {
        guard let r = rates(model) else { return 0 }
        let p = r.input / 1e6
        return Double(input) * p + Double(output) * r.output / 1e6 + Double(cacheRead) * p * 0.1
            + Double(write5m) * p * 1.25 + Double(write1h) * p * 2
    }
}

/// 持久化：每个日志文件已读到的位置 + 小时桶
struct TokenStats: Codable {
    struct FileState: Codable {
        var offset = 0
        var account: String?
        var model: String?
        var lastID: String?
        var lastTotal = 0
        var lastTS: Double = 0
    }
    var files: [String: FileState] = [:]
    /// key = "provider|model|hourEpoch"
    var buckets: [String: TokenBucket] = [:]
    var version = 1
    /// 统计起点：首次安装只回溯几天，之后一直增量累积
    var since: Double = 0
}

enum TokenStatsStore {
    static let file = AccountStore.dir.appendingPathComponent("tokens.json")
    static func load() -> TokenStats {
        guard let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(TokenStats.self, from: d) else { return TokenStats() }
        return s
    }
    static func save(_ s: TokenStats) {
        try? FileManager.default.createDirectory(at: AccountStore.dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: file, options: .atomic) }
    }
}

/// 增量扫描 Claude / Codex 的本地会话日志。只读，不上传
enum TokenScanner {
    static let keepDays = 8.0
    /// 首次扫描只回溯这么多天；之后靠增量累积，7 天视图会随使用时间自然填满
    static let initialDays = 2.0

    static func scan(_ stats: inout TokenStats, now: Date = Date()) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let cutoff = now.addingTimeInterval(-keepDays * 86400)
        var live = Set<String>()
        if stats.since == 0 { stats.since = now.addingTimeInterval(-initialDays * 86400).timeIntervalSince1970 }
        let firstCutoff = Date(timeIntervalSince1970: stats.since)
        for (root, provider) in [(home.appendingPathComponent(".claude/projects"), Provider.claude),
                                 (home.appendingPathComponent(".codex/sessions"), Provider.codex)] {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let mt = v?.contentModificationDate, mt >= cutoff, let size = v?.fileSize else { continue }
                var st = stats.files[url.path] ?? TokenStats.FileState()
                // 没扫过的文件：只处理起点之后还有改动的（旧文件直接忽略，不读）
                if stats.files[url.path] == nil && mt < firstCutoff { continue }
                live.insert(url.path)
                if size < st.offset { st = TokenStats.FileState() }   // 文件被截断/重写
                guard size > st.offset else { continue }
                autoreleasepool { scanFile(url, provider: provider, state: &st, stats: &stats) }
                stats.files[url.path] = st
            }
        }
        // 清理：不再存在/过期文件的状态，过期的小时桶
        stats.files = stats.files.filter { live.contains($0.key) }
        let minHour = cutoff.timeIntervalSince1970 - 3600
        stats.buckets = stats.buckets.filter { (Double($0.key.split(separator: "|").last ?? "0") ?? 0) >= minHour }
    }

    // MARK: 单文件

    private static func scanFile(_ url: URL, provider: Provider, state st: inout TokenStats.FileState, stats: inout TokenStats) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        var uuidTS: [String: String] = [:]
        let nl = UInt8(ascii: "\n")
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let buf = raw.bindMemory(to: UInt8.self)
            var pos = st.offset
            while pos < buf.count {
                var end = pos
                while end < buf.count && buf[end] != nl { end += 1 }
                if end >= buf.count { break }   // 最后一行还没写完，下次再读
                let line = UnsafeBufferPointer(rebasing: buf[pos..<end])
                pos = end + 1
                if line.isEmpty { continue }
                if provider == .claude { claudeLine(line, &st, &stats, &uuidTS) } else { codexLine(line, &st, &stats) }
            }
            st.offset = pos
        }
    }

    private static func contains(_ line: UnsafeBufferPointer<UInt8>, _ needle: StaticString) -> Bool {
        let n = needle.utf8CodeUnitCount
        guard line.count >= n else { return false }
        let p = needle.utf8Start
        let first = p[0]
        var i = 0
        let last = line.count - n
        while i <= last {
            if line[i] == first && memcmp(line.baseAddress! + i, p, n) == 0 { return true }
            i += 1
        }
        return false
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func ts(_ s: String?) -> Double? { s.flatMap { iso.date(from: $0) }?.timeIntervalSince1970 }

    private static func add(_ stats: inout TokenStats, _ provider: Provider, _ model: String, _ t: Double, _ b: TokenBucket) {
        if t < stats.since { return }
        let hour = Int(t / 3600) * 3600
        stats.buckets["\(provider.rawValue)|\(model)|\(hour)", default: TokenBucket()].add(b)
    }

    // MARK: Claude

    private static func claudeLine(_ line: UnsafeBufferPointer<UInt8>, _ st: inout TokenStats.FileState, _ stats: inout TokenStats, _ uuidTS: inout [String: String]) {
        if let u = field(line, "\"uuid\":\""), let t = field(line, "\"timestamp\":\"") {
            if uuidTS.count > 4000 { uuidTS.removeAll(keepingCapacity: true) }
            uuidTS[u] = t
        }
        if contains(line, "\"session-owner\"") {
            if let o = obj(line), let a = o["accountUuid"] as? String { st.account = a }
            return
        }
        guard contains(line, "\"usage\""), contains(line, "\"type\":\"assistant\"") || contains(line, "\"type\": \"assistant\"") else { return }
        guard let o = obj(line), o["type"] as? String == "assistant",
              let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
              let model = msg["model"] as? String, !model.hasPrefix("<"),
              let t = ts(o["timestamp"] as? String) else { return }
        // 同一条消息会按内容块拆成多行，用量相同，只记一次（取最后一行）
        let id = msg["id"] as? String
        if let id, id == st.lastID { return }
        st.lastID = id
        let inp = u["input_tokens"] as? Int ?? 0, out = u["output_tokens"] as? Int ?? 0
        let cr = u["cache_read_input_tokens"] as? Int ?? 0, cw = u["cache_creation_input_tokens"] as? Int ?? 0
        guard inp + out + cr + cw > 0 else { return }
        let cc = u["cache_creation"] as? [String: Any]
        let w1h = min(cw, cc?["ephemeral_1h_input_tokens"] as? Int ?? 0)
        var b = TokenBucket(input: inp, output: out, cacheRead: cr, cacheWrite: cw, messages: 1)
        b.cost = TokenPrice.cost(model, input: inp, output: out, cacheRead: cr, write5m: cw - w1h, write1h: w1h)
        if out >= 50, let p = o["parentUuid"] as? String, let pt = ts(uuidTS[p]), t - pt > 0.5, t - pt < 600 {
            b.speedTokens = out; b.speedSecs = t - pt
        }
        add(&stats, .claude, model, t, b)
    }

    // MARK: Codex

    private static func codexLine(_ line: UnsafeBufferPointer<UInt8>, _ st: inout TokenStats.FileState, _ stats: inout TokenStats) {
        if contains(line, "\"turn_context\"") {
            if let o = obj(line), let p = o["payload"] as? [String: Any], let m = p["model"] as? String { st.model = m }
            return
        }
        guard contains(line, "\"token_count\"") else { return }
        guard let o = obj(line), let p = o["payload"] as? [String: Any], p["type"] as? String == "token_count",
              let info = p["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any],
              let t = ts(o["timestamp"] as? String) else { return }
        let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int ?? 0
        defer { st.lastTS = t }
        if total > 0 && total == st.lastTotal { return }   // 重复上报
        st.lastTotal = total
        let inp = last["input_tokens"] as? Int ?? 0, cached = last["cached_input_tokens"] as? Int ?? 0
        let out = last["output_tokens"] as? Int ?? 0, rea = last["reasoning_output_tokens"] as? Int ?? 0
        let cw = last["cache_write_input_tokens"] as? Int ?? 0
        var b = TokenBucket(input: max(0, inp - cached), output: max(0, out - rea), cacheRead: cached, cacheWrite: cw, reasoning: rea, messages: 1)
        guard b.total > 0 else { return }
        if out >= 50, st.lastTS > 0, t - st.lastTS > 0.5, t - st.lastTS < 300 {
            b.speedTokens = out; b.speedSecs = t - st.lastTS
        }
        add(&stats, .codex, st.model ?? "codex", t, b)
    }

    /// 取 `"key":"value"` 的 value（不做 JSON 转义处理，仅用于 uuid / 时间戳）
    private static func field(_ line: UnsafeBufferPointer<UInt8>, _ key: StaticString) -> String? {
        let n = key.utf8CodeUnitCount, p = key.utf8Start
        guard line.count > n + 2 else { return nil }
        var i = 0
        // uuid / timestamp 都在行首附近；只扫前 600 字节
        let last = min(line.count, 600) - n
        while i <= last {
            if line[i] == p[0] && memcmp(line.baseAddress! + i, p, n) == 0 {
                var j = i + n
                let st = j
                while j < line.count && line[j] != UInt8(ascii: "\"") { j += 1 }
                return String(decoding: UnsafeBufferPointer(rebasing: line[st..<j]), as: UTF8.self)
            }
            i += 1
        }
        return nil
    }

    private static func obj(_ line: UnsafeBufferPointer<UInt8>) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(buffer: line)) as? [String: Any]
    }
}

// MARK: 汇总

struct UsageSummary {
    var total = TokenBucket()
    var byModel: [(model: String, b: TokenBucket)] = []
    var hasData: Bool { total.messages > 0 }
}

extension TokenStats {
    /// days = 1 → 今天（本地零点起），其余 → 最近 N×24 小时
    func summary(provider: Provider, days: Int, now: Date = Date()) -> UsageSummary {
        let start = days <= 1 ? Calendar.current.startOfDay(for: now) : now.addingTimeInterval(-Double(days) * 86400)
        let from = Int(start.timeIntervalSince1970 / 3600) * 3600
        var per: [String: TokenBucket] = [:]
        for (k, b) in buckets {
            let parts = k.split(separator: "|")
            guard parts.count == 3, parts[0] == provider.rawValue, let h = Int(parts[2]), h >= from else { continue }
            per[String(parts[1]), default: TokenBucket()].add(b)
        }
        var s = UsageSummary()
        for (_, b) in per { s.total.add(b) }
        s.byModel = per.map { ($0.key, $0.value) }.sorted { $0.1.total > $1.1.total }
        return s
    }
}

import Foundation

/// Codex 额度：GET chatgpt.com/backend-api/wham/usage（Codex 自己查额度用的同源接口，未公开）。
/// token 刷新：POST auth.openai.com/oauth/token（refresh_token 会轮换，所以要把新值写回 auth.json 和账号快照）。
enum CodexService {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func iso(_ d: Date = Date()) -> String { ISO8601DateFormatter().string(from: d) }

    static func load(_ account: Account, isActive: Bool) async -> UsageOutcome {
        let first = await attempt(account, isActive: isActive)
        // 活动账号的 refresh token 可能刚被 Codex 自己轮换过：重读 auth.json 再试一次
        if case .needsLogin = first, isActive { return await attempt(account, isActive: true) }
        return first
    }

    private static func attempt(_ account: Account, isActive: Bool) async -> UsageOutcome {
        let raw = isActive ? CodexLive.readAuth() : await AccountStore.secret(account)
        guard let raw, var json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              var tokens = json["tokens"] as? [String: Any],
              var access = tokens["access_token"] as? String else { return .failed(L("读不到凭证", "Credentials unreadable")) }
        let accountID = tokens["account_id"] as? String

        func persist() async {
            tokens["access_token"] = access
            json["tokens"] = tokens
            json["last_refresh"] = iso()
            guard let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let s = String(data: d, encoding: .utf8) else { return }
            if isActive { try? CodexLive.writeAuth(s) }
            _ = await AccountStore.setSecret(account, s)
        }

        /// true 成功 / false 凭证已失效 / nil 网络问题
        func refresh() async -> Bool? {
            guard let rt = tokens["refresh_token"] as? String else { return false }
            var req = URLRequest(url: tokenURL, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "client_id": clientID, "grant_type": "refresh_token", "refresh_token": rt, "scope": "openid profile email",
            ])
            var got: (Data, URLResponse)?
            for attempt in 0..<3 {
                do { got = try await URLSession.shared.data(for: req); break } catch let e as URLError {
                    let neverSent: Set<URLError.Code> = [.cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost]
                    guard neverSent.contains(e.code), attempt < 2 else { return nil }
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000)
                } catch { return nil }
            }
            guard let (data, resp) = got, let http = resp as? HTTPURLResponse else { return nil }
            if http.statusCode == 200, let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let a = r["access_token"] as? String { access = a }
                if let i = r["id_token"] as? String { tokens["id_token"] = i }
                if let n = r["refresh_token"] as? String { tokens["refresh_token"] = n }
                await persist()
                return true
            }
            return [400, 401, 403].contains(http.statusCode) ? false : nil
        }

        func fetch() async -> (Int, Data)? {
            var req = URLRequest(url: usageURL, timeoutInterval: 20)
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            if let accountID { req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
            req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
            var last: (Int, Data)?
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) }
                guard let (d, r) = try? await URLSession.shared.data(for: req), let h = r as? HTTPURLResponse else { continue }
                last = (h.statusCode, d)
                if h.statusCode < 500 && h.statusCode != 429 { break }
            }
            return last
        }

        var refreshed = false
        let exp = (JWT.claims(access)?["exp"] as? NSNumber)?.doubleValue ?? 0
        if exp < Date().timeIntervalSince1970 + 90 {
            switch await refresh() {
            case .some(true): refreshed = true
            case .some(false): return .needsLogin
            case .none: return .failed(L("网络异常，无法刷新登录", "Network error; could not refresh the login"))
            }
        }
        guard var res = await fetch() else { return .failed(L("网络异常", "Network error")) }
        if res.0 == 401, !refreshed {
            switch await refresh() {
            case .some(true): guard let r2 = await fetch() else { return .failed(L("网络异常", "Network error")) }; res = r2
            case .some(false): return .needsLogin
            case .none: return .failed(L("网络异常，无法刷新登录", "Network error; could not refresh the login"))
            }
        }
        if res.0 == 401 { return .needsLogin }
        if res.0 == 429 { return .failed(L("请求过于频繁，稍后自动重试", "Too many requests; will retry automatically")) }
        guard res.0 == 200, let j = (try? JSONSerialization.jsonObject(with: res.1)) as? [String: Any] else {
            return .failed(L("额度接口返回 \(res.0)", "Quota API returned \(res.0)"))
        }
        return .ok(parse(j))
    }

    /// primary / secondary 窗口按时长归类：≤ 6 小时算「5 小时」，否则算「每周」（免费档只有周窗口）
    static func parse(_ j: [String: Any]) -> UsageInfo {
        let rl = j["rate_limit"] as? [String: Any]
        var session: Meter?, weekly: Meter?
        for key in ["primary_window", "secondary_window"] {
            guard let w = rl?[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let secs = (w["limit_window_seconds"] as? NSNumber)?.doubleValue ?? (key == "primary_window" ? 18000 : 604800)
            var reset: Date?
            if let at = (w["reset_at"] as? NSNumber)?.doubleValue, at > 0 { reset = Date(timeIntervalSince1970: at) }
            else if let after = (w["reset_after_seconds"] as? NSNumber)?.doubleValue { reset = Date().addingTimeInterval(after) }
            let m = Meter(remaining: max(0, min(100, 100 - used)), resetsAt: reset)
            if secs <= 6 * 3600 { session = m } else { weekly = m }
        }
        return UsageInfo(session: session, weekly: weekly, opus: nil, sonnet: nil, fetchedAt: Date())
    }
}

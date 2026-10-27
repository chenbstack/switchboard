import Foundation

/// 额度：GET api.anthropic.com/api/oauth/usage（Claude Code `/usage` 同源接口）
enum UsageService {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func meter(_ any: Any?) -> Meter? {
        guard let d = any as? [String: Any], let u = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return Meter(remaining: max(0, min(100, 100 - u)), resetsAt: parseDate(d["resets_at"] as? String))
    }

    static func load(_ account: Account, isActive: Bool) async -> UsageOutcome {
        let raw = isActive ? await ClaudeLive.readCredential() : await AccountStore.secret(account)
        guard let raw, var json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              var oauth = json["claudeAiOauth"] as? [String: Any],
              var access = oauth["accessToken"] as? String else { return .failed(L("读不到凭证", "Credentials unreadable")) }

        func persist() async {
            json["claudeAiOauth"] = oauth
            guard let d = try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes]),
                  let s = String(data: d, encoding: .utf8) else { return }
            if isActive { _ = await ClaudeLive.writeCredential(s) }
            _ = await AccountStore.setSecret(account, s)   // 活动账号也同步快照
        }

        /// true 成功 / false 凭证已失效 / nil 网络问题
        func refresh() async -> Bool? {
            guard let rt = oauth["refreshToken"] as? String else { return false }
            var req = URLRequest(url: tokenURL, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": rt, "client_id": clientID]
            if let sc = oauth["scopes"] as? [String] { body["scope"] = sc.joined(separator: " ") }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            var got: (Data, URLResponse)?
            for attempt in 0..<3 {
                do { got = try await URLSession.shared.data(for: req); break } catch let e as URLError {
                    let neverSent: Set<URLError.Code> = [.cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost]
                    guard neverSent.contains(e.code), attempt < 2 else { return nil }
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000)
                } catch { return nil }
            }
            guard let (data, resp) = got, let http = resp as? HTTPURLResponse else { return nil }
            if http.statusCode == 200, let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let a = r["access_token"] as? String {
                access = a
                oauth["accessToken"] = a
                if let n = r["refresh_token"] as? String { oauth["refreshToken"] = n }
                let life = (r["expires_in"] as? NSNumber)?.doubleValue ?? 3600
                oauth["expiresAt"] = Int64((Date().timeIntervalSince1970 + life) * 1000)
                await persist()
                return true
            }
            return [400, 401, 403].contains(http.statusCode) ? false : nil
        }

        func fetch() async -> (Int, Data)? {
            var req = URLRequest(url: usageURL, timeoutInterval: 20)
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
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
        let exp = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        if exp / 1000 < Date().timeIntervalSince1970 + 90 {
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
        return .ok(UsageInfo(session: meter(j["five_hour"]), weekly: meter(j["seven_day"]),
                             opus: meter(j["seven_day_opus"]), sonnet: meter(j["seven_day_sonnet"]),
                             fetchedAt: Date()))
    }
}

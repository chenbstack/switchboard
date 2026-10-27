import Foundation
import CryptoKit

/// 解析 JWT 载荷（不验签，仅读取 claims）
enum JWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

/// Codex（ChatGPT 订阅登录）的当前登录态：$CODEX_HOME/auth.json（默认 ~/.codex/auth.json）。
/// 读写、额度查询、刷新都不需要 codex 命令行。
enum CodexLive {
    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["CODEX_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    static var authFile: URL { home.appendingPathComponent("auth.json") }

    static func readAuth() -> String? {
        guard let d = try? Data(contentsOf: authFile) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// 原子写入，权限 0600（和 codex 自己一致）
    static func writeAuth(_ s: String) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(s.utf8).write(to: authFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
    }

    /// 没有 auth.json、但钥匙串里有 Codex 的登录：说明 codex 用了 keyring 存储，这种方式暂不支持读写
    static func usesKeyringOnly() async -> Bool {
        guard !FileManager.default.fileExists(atPath: authFile.path) else { return false }
        return await Keychain.exists(service: "Codex Auth")
    }

    static func identity() -> LiveIdentity? { readAuth().flatMap(identity(of:)) }

    /// 从 auth.json 文本里取出账号身份；只认 ChatGPT 订阅登录（有 tokens），API key 模式不算账号
    static func identity(of auth: String) -> LiveIdentity? {
        guard let j = (try? JSONSerialization.jsonObject(with: Data(auth.utf8))) as? [String: Any],
              let t = j["tokens"] as? [String: Any], let idt = t["id_token"] as? String,
              let c = JWT.claims(idt) else { return nil }
        let authClaims = c["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let profile = c["https://api.openai.com/profile"] as? [String: Any] ?? [:]
        let email = (c["email"] as? String) ?? (profile["email"] as? String) ?? ""
        let key = (authClaims["chatgpt_user_id"] as? String) ?? (authClaims["user_id"] as? String)
            ?? (t["account_id"] as? String) ?? email
        guard !key.isEmpty else { return nil }
        return LiveIdentity(uuid: key, email: email, plan: planName(authClaims["chatgpt_plan_type"] as? String))
    }

    static func planName(_ raw: String?) -> String {
        switch (raw ?? "").lowercased() {
        case "": return "ChatGPT"
        case "prolite": return "Pro Lite"
        case "promax": return "Pro Max"
        case "free_workspace": return "Free"
        case let s where s.hasPrefix("enterprise") || s == "ent26": return "Enterprise"
        case let s where s.hasPrefix("self_serve_business") || s == "business": return "Business"
        case let s where s.hasPrefix("edu"): return "Edu"
        case let s: return s.prefix(1).uppercased() + s.dropFirst()
        }
    }
}

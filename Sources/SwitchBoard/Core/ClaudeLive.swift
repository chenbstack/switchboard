import Foundation

/// Claude Code 当前「生效」的登录态：钥匙串里的凭证 + ~/.claude.json 里的 oauthAccount
enum ClaudeLive {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let claudeJSON = home.appendingPathComponent(".claude.json")
    static let settingsFile = home.appendingPathComponent(".claude/settings.json")
    static let service = "Claude Code-credentials"

    static func planName(_ org: String?) -> String {
        let s = (org ?? "").lowercased()
        if s.contains("max") { return "Max" }
        if s.contains("team") { return "Team" }
        if s.contains("enterprise") { return "Enterprise" }
        if s.contains("pro") { return "Pro" }
        return org == nil ? "—" : "Free"
    }

    static func oauthAccount() -> JSONValue? {
        guard let j = FileJSON.read(claudeJSON), let a = j["oauthAccount"] else { return nil }
        return JSONValue(any: a)
    }

    static func identity() -> LiveIdentity? {
        guard let a = oauthAccount(), let uuid = a["accountUuid"]?.string else { return nil }
        return LiveIdentity(uuid: uuid, email: a["emailAddress"]?.string ?? "",
                            plan: planName(a["organizationType"]?.string))
    }

    static func readCredential() async -> String? {
        guard let acct = await Keychain.accountName(service: service) else { return nil }
        return await Keychain.read(service: service, account: acct)
    }

    static func writeCredential(_ value: String) async -> Bool {
        let acct = await Keychain.accountName(service: service) ?? NSUserName()
        return await Keychain.write(service: service, account: acct, value: value)
    }

    static func setOAuthAccount(_ acct: JSONValue) throws {
        guard var j = FileJSON.read(claudeJSON) else { throw AppError(L("无法读取 ~/.claude.json", "Could not read ~/.claude.json")) }
        // 首次改写前留一份备份
        let bak = claudeJSON.appendingPathExtension("switchboard.bak")
        if !FileManager.default.fileExists(atPath: bak.path) { try? FileManager.default.copyItem(at: claudeJSON, to: bak) }
        j["oauthAccount"] = acct.any
        try FileJSON.write(j, to: claudeJSON)
    }

    // MARK: 自定义 API（写入 settings.json 的 env，优先级高于 OAuth 登录）

    /// 记录「当前生效的是哪个 API 账号」的标记；有它才认为 env 是 SwitchBoard 写的
    static let marker = "SWITCHBOARD_ACCOUNT"
    static let managedKeys = ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL",
                              "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", marker]

    static func activeAPIID() -> String? {
        (FileJSON.read(settingsFile)?["env"] as? [String: Any])?[marker] as? String
    }

    private static func editEnv(_ body: (inout [String: Any]) -> Void) throws {
        var j = FileJSON.read(settingsFile) ?? [:]
        if FileManager.default.fileExists(atPath: settingsFile.path) {
            let bak = settingsFile.appendingPathExtension("switchboard.bak")
            if !FileManager.default.fileExists(atPath: bak.path) { try? FileManager.default.copyItem(at: settingsFile, to: bak) }
        }
        var env = j["env"] as? [String: Any] ?? [:]
        body(&env)
        if env.isEmpty { j.removeValue(forKey: "env") } else { j["env"] = env }
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileJSON.write(j, to: settingsFile)
    }

    static func applyAPI(_ acc: Account, key: String) throws {
        guard let api = acc.api else { return }
        try editEnv { env in
            for k in managedKeys { env.removeValue(forKey: k) }
            env["ANTHROPIC_BASE_URL"] = api.baseURL
            env["ANTHROPIC_AUTH_TOKEN"] = key
            if !api.model.isEmpty { env["ANTHROPIC_MODEL"] = api.model }
            if !api.subagent.isEmpty { env["CLAUDE_CODE_SUBAGENT_MODEL"] = api.subagent }
            if !api.opus.isEmpty { env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = api.opus }
            if !api.sonnet.isEmpty { env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = api.sonnet }
            if !api.haiku.isEmpty { env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = api.haiku }
            env[marker] = acc.id
        }
    }

    /// 只在 env 是我们写入的（有标记）时才清理，不动用户自己手写的配置
    static func clearAPI() throws {
        guard activeAPIID() != nil else { return }
        try editEnv { env in for k in managedKeys { env.removeValue(forKey: k) } }
    }
}

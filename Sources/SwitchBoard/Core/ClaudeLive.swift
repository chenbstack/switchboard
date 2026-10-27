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
        guard var j = FileJSON.read(claudeJSON) else { throw AppError("无法读取 ~/.claude.json") }
        // 首次改写前留一份备份
        let bak = claudeJSON.appendingPathExtension("switchboard.bak")
        if !FileManager.default.fileExists(atPath: bak.path) { try? FileManager.default.copyItem(at: claudeJSON, to: bak) }
        j["oauthAccount"] = acct.any
        try FileJSON.write(j, to: claudeJSON)
    }
}

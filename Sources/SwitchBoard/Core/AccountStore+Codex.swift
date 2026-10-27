import Foundation

/// Codex 账号：凭证就是整份 auth.json，同样存进 Vault；元数据和 Claude 账号放在同一个 accounts.json 里（provider = codex）
extension AccountStore {
    private static func validCodexAuth(_ s: String) -> Bool {
        guard let j = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
              let t = j["tokens"] as? [String: Any], t["refresh_token"] is String, t["access_token"] is String else { return false }
        return true
    }

    static func addCurrentCodex(name: String, existing: [Account]) async throws -> Account {
        guard let auth = CodexLive.readAuth(), CodexLive.identity(of: auth) != nil else {
            throw AppError("当前没有 Codex 的 ChatGPT 登录（API key 方式不是账号）")
        }
        return try await addCodex(name: name, auth: auth, existing: existing)
    }

    static func addCodex(name: String, auth: String, existing: [Account]) async throws -> Account {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw AppError("请输入账号名称") }
        guard !existing.contains(where: { $0.name == name }) else { throw AppError("已存在同名账号") }
        guard validCodexAuth(auth), let id = CodexLive.identity(of: auth) else { throw AppError("登录信息不完整") }
        guard !existing.contains(where: { $0.provider == .codex && $0.uuid == id.uuid }) else { throw AppError("该账号已经添加过了") }
        let acc = Account(id: UUID().uuidString, name: name, email: id.email, uuid: id.uuid, plan: id.plan,
                          oauth: .null, addedAt: Date(), provider: .codex)
        guard await setSecret(acc, auth) else { throw AppError("写入钥匙串失败") }
        try save(existing + [acc])
        return acc
    }

    static func replaceCodexCredential(_ acc: Account, auth: String, in accounts: [Account]) async throws -> [Account] {
        guard validCodexAuth(auth), let id = CodexLive.identity(of: auth) else { throw AppError("登录信息不完整") }
        guard await setSecret(acc, auth) else { throw AppError("写入钥匙串失败") }
        var a = acc
        a.email = id.email
        a.plan = id.plan
        let updated = accounts.map { $0.id == a.id ? a : $0 }
        try save(updated)
        return updated
    }

    /// Codex 会轮换 refresh token，和 Claude 一样：刷新/切换前把当前 auth.json 回写到对应账号
    static func syncLiveCodex(into accounts: [Account]) async -> [Account] {
        guard let auth = CodexLive.readAuth(), validCodexAuth(auth), let live = CodexLive.identity(of: auth),
              var acc = accounts.first(where: { $0.provider == .codex && $0.uuid == live.uuid }) else { return accounts }
        if let old = await secret(acc), old == auth, acc.email == live.email, acc.plan == live.plan { return accounts }
        _ = await setSecret(acc, auth)
        acc.email = live.email
        acc.plan = live.plan
        let updated = accounts.map { $0.id == acc.id ? acc : $0 }
        try? save(updated)
        return updated
    }

    static func switchToCodex(_ target: Account, accounts: [Account]) async throws -> [Account] {
        if await CodexLive.usesKeyringOnly() {
            throw AppError("Codex 把登录存在了钥匙串里，暂不支持切换。请在 ~/.codex/config.toml 设置 cli_auth_credentials_store = \"file\" 后重新登录")
        }
        let synced = await syncLiveCodex(into: accounts)
        guard let auth = await secret(target), validCodexAuth(auth) else {
            throw AppError("该账号的已存凭证丢失，请重新登录添加")
        }
        do { try CodexLive.writeAuth(auth) } catch { throw AppError("写入 Codex 登录失败：\(error.localizedDescription)") }
        guard CodexLive.identity()?.uuid == target.uuid else { throw AppError("切换后校验失败，请重试") }
        return synced
    }
}

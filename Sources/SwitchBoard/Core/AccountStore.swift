import Foundation
import CryptoKit
import Security

/// 账号库：元数据在 Application Support，所有账号凭证合并存放在钥匙串的同一条目里（见 Vault）
enum AccountStore {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SwitchBoard")
    static let file = dir.appendingPathComponent("accounts.json")
    static let secretService = "SwitchBoard"
    // 改名前（ClaudeSwitch）的数据位置，首次启动时迁移
    static let legacyService = "ClaudeSwitch"
    static let legacyDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeSwitch")

    static func migrateLegacyDir() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyDir.path), !fm.fileExists(atPath: dir.path) else { return }
        try? fm.moveItem(at: legacyDir, to: dir)
    }

    // MARK: 持久化

    static func load() -> [Account] {
        migrateLegacyDir()
        guard let d = try? Data(contentsOf: file) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return ((try? dec.decode([Account].self, from: d)) ?? []).sorted { $0.addedAt < $1.addedAt }
    }

    // MARK: 额度缓存（非敏感，仅用于启动时先展示上次数据）

    static let usageFile = dir.appendingPathComponent("usage.json")

    static func loadUsage() -> [String: UsageInfo] {
        migrateLegacyDir()
        guard let d = try? Data(contentsOf: usageFile) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: UsageInfo].self, from: d)) ?? [:]
    }

    static func saveUsage(_ usage: [String: UsageInfo]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(usage).write(to: usageFile, options: .atomic)
    }

    static func save(_ accounts: [Account]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(accounts).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func secret(_ a: Account) async -> String? { await Vault.shared.get(a.id) }
    static func setSecret(_ a: Account, _ v: String) async -> Bool { await Vault.shared.set(a.id, v) }

    static func suggestName(email: String, existing: [Account]) -> String {
        var base = String(email.split(separator: "@").first ?? "account")
        base = base.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        if base.isEmpty { base = "account" }
        var name = base, i = 2
        while existing.contains(where: { $0.name == name }) { name = "\(base)-\(i)"; i += 1 }
        return name
    }

    // MARK: 把「当前登录会话」保存为账号

    static func addCurrent(name: String, existing: [Account]) async throws -> Account {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw AppError(L("请输入账号名称", "Please enter an account name")) }
        guard !existing.contains(where: { $0.name == name }) else { throw AppError(L("已存在同名账号", "An account with this name already exists")) }
        guard let oauth = ClaudeLive.oauthAccount(), let uuid = oauth["accountUuid"]?.string else {
            throw AppError(L("当前没有 Claude 登录会话，请先在 Claude Code 中登录", "No Claude login session found. Please log in with Claude Code first"))
        }
        guard !existing.contains(where: { $0.uuid == uuid }) else { throw AppError(L("该账号已经添加过了", "This account has already been added")) }
        guard let cred = await ClaudeLive.readCredential() else { throw AppError(L("未找到当前登录凭证", "Could not find the current login credentials")) }
        return try await add(name: name, cred: cred, oauth: oauth, existing: existing)
    }

    /// 用给定的凭证 + 账号信息新增账号（不依赖当前登录）
    static func add(name: String, cred: String, oauth: JSONValue, existing: [Account]) async throws -> Account {
        guard let uuid = oauth["accountUuid"]?.string else { throw AppError(L("账号信息不完整", "The account information is incomplete")) }
        let acc = Account(id: UUID().uuidString, name: name, email: oauth["emailAddress"]?.string ?? "",
                          uuid: uuid, plan: ClaudeLive.planName(oauth["organizationType"]?.string),
                          oauth: oauth, addedAt: Date())
        guard await setSecret(acc, cred) else { throw AppError(L("写入钥匙串失败", "Failed to write to the Keychain")) }
        try save(existing + [acc])
        return acc
    }

    /// 为已有账号换上新登录的凭证（重新登录）
    static func replaceCredential(_ acc: Account, cred: String, oauth: JSONValue, in accounts: [Account]) async throws -> [Account] {
        guard await setSecret(acc, cred) else { throw AppError(L("写入钥匙串失败", "Failed to write to the Keychain")) }
        var a = acc
        a.oauth = oauth
        a.plan = ClaudeLive.planName(oauth["organizationType"]?.string)
        let updated = accounts.map { $0.id == a.id ? a : $0 }
        try save(updated)
        return updated
    }

    static func rename(_ id: String, to name: String, in accounts: [Account]) throws -> [Account] {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw AppError(L("请输入账号名称", "Please enter an account name")) }
        guard !accounts.contains(where: { $0.name == name && $0.id != id }) else { throw AppError(L("已存在同名账号", "An account with this name already exists")) }
        var all = accounts
        if let i = all.firstIndex(where: { $0.id == id }) { all[i].name = name }
        try save(all)
        return all
    }

    static func remove(_ a: Account, from accounts: [Account]) async throws -> [Account] {
        await Vault.shared.remove(a.id)
        let rest = accounts.filter { $0.id != a.id }
        try save(rest)
        return rest
    }

    // MARK: 自定义 API 账号

    static func normalizeURL(_ raw: String) throws -> String {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        guard let url = URL(string: u), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            throw AppError(L("请输入有效的 Base URL（以 http:// 或 https:// 开头）", "Please enter a valid Base URL (starting with http:// or https://)"))
        }
        return u
    }

    /// id = nil 新增；否则编辑（key 留空表示不改密钥）
    static func saveAPI(id: String?, provider: Provider = .claude, name: String, config: APIConfig, key: String, existing: [Account]) async throws -> [Account] {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw AppError(L("请输入账号名称", "Please enter an account name")) }
        guard !existing.contains(where: { $0.name == name && $0.id != id }) else { throw AppError(L("已存在同名账号", "An account with this name already exists")) }
        var cfg = config
        cfg.baseURL = try normalizeURL(config.baseURL)
        for k in [\.model, \.opus, \.sonnet, \.haiku, \.subagent] as [WritableKeyPath<APIConfig, String>] { cfg[keyPath: k] = cfg[keyPath: k].trimmingCharacters(in: .whitespaces) }
        cfg.catalogModels = cfg.catalogModels.map { ModelMap(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), target: $0.target.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.target.isEmpty }.map { ModelMap(name: $0.name.isEmpty ? $0.target : $0.name, target: $0.target) }
        if provider == .codex, cfg.catalog, cfg.catalogModels.isEmpty { throw AppError(L("开启模型映射需要至少选择一个模型", "Model mapping needs at least one model")) }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var all = existing
        if let id, let i = all.firstIndex(where: { $0.id == id }) {
            if !key.isEmpty { guard await Vault.shared.set(id, key) else { throw AppError(L("写入钥匙串失败", "Failed to write to the Keychain")) } }
            all[i].name = name; all[i].api = cfg; all[i].email = cfg.host
        } else {
            guard !key.isEmpty else { throw AppError(L("请输入 API 密钥", "Please enter the API key")) }
            let newID = UUID().uuidString
            guard await Vault.shared.set(newID, key) else { throw AppError(L("写入钥匙串失败", "Failed to write to the Keychain")) }
            all.append(Account(id: newID, name: name, email: cfg.host, uuid: "api-" + newID, plan: "API",
                               oauth: .null, addedAt: Date(), provider: provider, api: cfg))
        }
        try save(all)
        return all
    }

    static func switchToAPI(_ target: Account, accounts: [Account]) async throws -> [Account] {
        let synced = await syncLive(into: accounts)   // 离开前把 OAuth 登录态回写，避免 refresh token 过期
        guard let key = await Vault.shared.get(target.id), !key.isEmpty else {
            throw AppError(L("该账号的 API 密钥丢失，请编辑后重新输入", "The API key for this account is missing. Edit it and enter the key again"))
        }
        try ClaudeLive.applyAPI(target, key: key)
        guard ClaudeLive.activeAPIID() == target.id else { throw AppError(L("写入 ~/.claude/settings.json 失败，请重试", "Failed to write ~/.claude/settings.json. Please try again")) }
        return synced
    }

    static func switchToCodexAPI(_ target: Account, accounts: [Account]) async throws -> [Account] {
        let synced = await syncLiveCodex(into: accounts)   // 离开前把订阅登录态回写
        guard let key = await Vault.shared.get(target.id), !key.isEmpty else {
            throw AppError(L("该账号的 API 密钥丢失，请编辑后重新输入", "The API key for this account is missing. Edit it and enter the key again"))
        }
        do { try CodexConfig.applyAPI(target, key: key) } catch let e as AppError { throw e } catch {
            throw AppError(L("写入 ~/.codex/config.toml 失败：\(error.localizedDescription)", "Failed to write ~/.codex/config.toml: \(error.localizedDescription)"))
        }
        guard CodexConfig.activeAPIID() == target.id else { throw AppError(L("写入 ~/.codex/config.toml 失败，请重试", "Failed to write ~/.codex/config.toml. Please try again")) }
        return synced
    }

    // MARK: 保持快照新鲜
    // Claude Code 会轮换 refresh token；若快照里还是旧的，之后切回该账号就会「登录已失效」。
    // 所以每次刷新/切换前，把当前登录态回写到对应账号。

    static func syncLive(into accounts: [Account]) async -> [Account] {
        guard let live = ClaudeLive.identity(), var acc = accounts.first(where: { $0.uuid == live.uuid }),
              let cred = await ClaudeLive.readCredential(),
              (try? JSONSerialization.jsonObject(with: Data(cred.utf8))) != nil else { return accounts }
        if let old = await secret(acc), old == cred, acc.oauth == ClaudeLive.oauthAccount() { return accounts }
        _ = await setSecret(acc, cred)
        guard let oauth = ClaudeLive.oauthAccount() else { return accounts }
        acc.oauth = oauth
        acc.email = oauth["emailAddress"]?.string ?? acc.email
        acc.plan = ClaudeLive.planName(oauth["organizationType"]?.string)
        let updated = accounts.map { $0.id == acc.id ? acc : $0 }
        try? save(updated)
        return updated
    }

    // MARK: 全局切换

    static func switchTo(_ target: Account, accounts: [Account]) async throws -> [Account] {
        let synced = await syncLive(into: accounts)
        guard let cred = await secret(target),
              let obj = (try? JSONSerialization.jsonObject(with: Data(cred.utf8))) as? [String: Any],
              obj["claudeAiOauth"] != nil else {
            throw AppError(L("该账号的已存凭证丢失，请重新登录添加", "The saved credentials for this account are missing. Please log in and add it again"))
        }
        try ClaudeLive.clearAPI()   // 从 API 账号切回时，去掉 settings.json 里的中转站配置
        guard await ClaudeLive.writeCredential(cred) else { throw AppError(L("写入 Claude Code 凭证失败", "Failed to write the Claude Code credentials")) }
        try ClaudeLive.setOAuthAccount(target.oauth)
        guard ClaudeLive.identity()?.uuid == target.uuid else { throw AppError(L("切换后校验失败，~/.claude.json 可能被其他进程覆盖，请重试", "Verification after switching failed. ~/.claude.json may have been overwritten by another process. Please try again")) }
        return synced
    }
}

/// 所有账号的凭证合并为钥匙串里的一条（service = SwitchBoard，account = vault，值为 {账号id: 凭证JSON}）。
/// 只有一个条目，系统授权只需要确认一次；读到的内容缓存在内存里，避免反复访问钥匙串。
actor Vault {
    static let shared = Vault()
    private let service = AccountStore.secretService
    private let account = "vault"
    private var cache: [String: String]?

    private func load() async -> [String: String] {
        if let cache { return cache }
        var dict: [String: String] = [:]
        if let raw = nativeRead(), let d = Self.decode(raw) {
            dict = d
        } else {
            // 迁移：早期版本每个账号一条（account = 账号id），合并进 vault 后删除旧条目
            let ids = AccountStore.load().map(\.id)
            for id in ids {
                if let v = await Keychain.read(service: service, account: id) { dict[id] = v }
            }
            if !dict.isEmpty, await write(dict) {
                for id in dict.keys { await Keychain.delete(service: service, account: id) }
            }
        }
        // 改名迁移（ClaudeSwitch → SwitchBoard）：把旧 vault 里新 vault 没有的账号补进来，只做一次。
        // 不能"新的读不到才读旧的"：新 vault 可能先被当前账号的同步写成只含一个账号的残缺版本。
        let migratedKey = "vaultMigratedFromClaudeSwitch"
        if !UserDefaults.standard.bool(forKey: migratedKey) {
            if let raw = nativeRead(service: AccountStore.legacyService), let old = Self.decode(raw) {
                let missing = old.filter { dict[$0.key] == nil }
                var ok = true
                if !missing.isEmpty {
                    dict.merge(missing) { $1 }
                    ok = await write(dict)
                }
                if ok { UserDefaults.standard.set(true, forKey: migratedKey) }
            } else if !legacyExists() {
                UserDefaults.standard.set(true, forKey: migratedKey)   // 没有旧数据，无需再查
            }
        }
        cache = dict
        return dict
    }

    private func write(_ dict: [String: String]) async -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return false }
        return nativeWrite(s)
    }

    // 直接用系统钥匙串 API：不受 `security -i` 单行长度限制，密钥也不经过命令行参数
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func decode(_ raw: String) -> [String: String]? {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: String]
    }

    private func legacyExists() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: AccountStore.legacyService, kSecAttrAccount as String: account]
        return SecItemCopyMatching(q as CFDictionary, nil) != errSecItemNotFound
    }

    private func nativeRead(service: String? = nil) -> String? {
        var out: CFTypeRef?
        var q = query
        if let service { q[kSecAttrService as String] = service }
        let st = SecItemCopyMatching(q.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &out)
        guard st == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func nativeWrite(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let st = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecSuccess { return true }
        guard st == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    func get(_ id: String) async -> String? { await load()[id] }

    func set(_ id: String, _ value: String) async -> Bool {
        var dict = await load()
        if dict[id] == value { return true }
        dict[id] = value
        guard await write(dict) else { return false }
        cache = dict
        return true
    }

    func remove(_ id: String) async {
        var dict = await load()
        guard dict.removeValue(forKey: id) != nil else { return }
        if await write(dict) { cache = dict }
    }
}

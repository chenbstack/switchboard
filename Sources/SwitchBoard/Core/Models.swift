import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
    var symbol: String { self == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right" }
}

/// Codex 模型映射的一条：name = 在 Codex 里显示的名字，target = 中转站实际的模型（请求里发的名字）
struct ModelMap: Codable, Equatable {
    var name = ""
    var target = ""
}

/// 自定义 API / 中转站：切换时写入 ~/.claude/settings.json 的 env；密钥存在 Vault 里
struct APIConfig: Codable, Equatable {
    var baseURL: String
    /// 默认模型（ANTHROPIC_MODEL）：新会话默认使用，留空 = 用 Claude Code 自己的默认
    var model = ""
    /// 模型映射：Claude Code 里的 opus / sonnet / haiku 别名 → 中转站实际模型名（留空 = 不映射）
    var opus = ""
    var sonnet = ""
    var haiku = ""
    /// 子代理模型（CLAUDE_CODE_SUBAGENT_MODEL）
    var subagent = ""
    /// Codex 专用：是否开启模型映射（写 model_catalog_json，实验性），默认关闭
    var catalog = false
    /// Codex 专用：开启映射后，中转站实际提供的模型名
    var catalogModels: [ModelMap] = []

    var host: String { URL(string: baseURL)?.host ?? baseURL }
    var hasMapping: Bool { !(model.isEmpty && opus.isEmpty && sonnet.isEmpty && haiku.isEmpty && subagent.isEmpty) }
}

extension APIConfig {
    /// 旧版本保存的配置没有 catalog 相关字段
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        opus = try c.decodeIfPresent(String.self, forKey: .opus) ?? ""
        sonnet = try c.decodeIfPresent(String.self, forKey: .sonnet) ?? ""
        haiku = try c.decodeIfPresent(String.self, forKey: .haiku) ?? ""
        subagent = try c.decodeIfPresent(String.self, forKey: .subagent) ?? ""
        catalog = try c.decodeIfPresent(Bool.self, forKey: .catalog) ?? false
        catalogModels = try c.decodeIfPresent([ModelMap].self, forKey: .catalogModels) ?? []
    }
}

struct Account: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var email: String
    var uuid: String          // Anthropic accountUuid，用于和「当前登录」对应
    var plan: String
    var oauth: JSONValue      // 原样保存的 oauthAccount，切换时写回 ~/.claude.json
    var addedAt: Date
    var provider: Provider = .claude
    var api: APIConfig?       // 非空 = 自定义 API 账号（没有 OAuth 登录态）

    init(id: String, name: String, email: String, uuid: String, plan: String, oauth: JSONValue, addedAt: Date, provider: Provider = .claude, api: APIConfig? = nil) {
        self.id = id; self.name = name; self.email = email; self.uuid = uuid; self.plan = plan
        self.oauth = oauth; self.addedAt = addedAt; self.provider = provider; self.api = api
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        email = try c.decode(String.self, forKey: .email)
        uuid = try c.decode(String.self, forKey: .uuid)
        plan = try c.decode(String.self, forKey: .plan)
        oauth = try c.decode(JSONValue.self, forKey: .oauth)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .claude   // 旧版本没有这个字段
        api = try c.decodeIfPresent(APIConfig.self, forKey: .api)
    }

    /// 展示用订阅类型：Pro / Max 5x / Max 20x / Team / Enterprise
    var planLabel: String {
        if provider == .codex { return plan }
        let tier = (oauth["organizationRateLimitTier"]?.string ?? oauth["userRateLimitTier"]?.string ?? "").lowercased()
        if plan == "Max" {
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
        }
        return plan
    }
}

struct LiveIdentity: Equatable {
    let uuid: String
    let email: String
    let plan: String
}

struct Meter: Equatable, Codable {
    var remaining: Double   // 0...100
    var resetsAt: Date?
}

struct UsageInfo: Equatable, Codable {
    var session: Meter?
    var weekly: Meter?
    var opus: Meter?
    var sonnet: Meter?
    var fetchedAt: Date
}

enum UsageOutcome {
    case ok(UsageInfo)
    case needsLogin
    case failed(String)
}

struct AppError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

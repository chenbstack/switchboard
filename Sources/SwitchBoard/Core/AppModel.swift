import Foundation
import SwiftUI
import AppKit
import ServiceManagement

enum AccountStatus: Equatable {
    case loading
    case needsLogin
    case error(String)
}

enum Route: Equatable {
    case list
    case save            // 保存当前登录会话
    case rename(String)  // 账号 id
    case waitingLogin
    case addAPI          // 添加自定义 API
    case editAPI(String) // 编辑自定义 API，账号 id
}

@MainActor
final class AppModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var live: LiveIdentity?
    @Published var usage: [String: UsageInfo] = [:]
    @Published var status: [String: AccountStatus] = [:]
    @Published var route: Route = .list
    @Published var draftName = ""
    @Published var draftBaseURL = ""
    @Published var draftKey = ""
    @Published var draftOpus = ""
    @Published var draftSonnet = ""
    @Published var draftHaiku = ""
    @Published var draftModel = ""
    @Published var draftSubagent = ""
    /// 表单里「获取模型列表」的结果
    @Published var apiModels: [String] = []
    @Published var modelsLoading = false
    @Published var modelsError: String?
    /// 当前生效的自定义 API 账号 id（settings.json 里的标记）
    @Published var apiActive: String?
    /// 连通性探测通过的 API 账号
    @Published var apiOK: Set<String> = []
    @Published var formError: String?
    @Published var toast: String?
    @Published var update: UpdateInfo?
    /// 界面语言：auto 跟随系统；切换后触发整个面板重绘
    @Published var language: String = UserDefaults.standard.string(forKey: "language") ?? "auto" {
        didSet { UserDefaults.standard.set(language, forKey: "language"); Lang.override = language; onChange?() }
    }
    /// 自动刷新间隔（秒），0 = 仅手动刷新
    @Published var refreshInterval: Int = UserDefaults.standard.object(forKey: "refreshInterval") as? Int ?? 300 {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval"); scheduleTimer() }
    }
    @Published var updating = false
    @Published var switching: String?
    @Published var refreshing = false
    /// 用户手动点击刷新触发的刷新（只有这种情况刷新按钮才转圈）
    @Published var manualRefreshing = false
    @Published var lastUpdated: Date?
    @Published var launchAtLogin = false
    @Published var loginURL: String?
    @Published var loginNote: String?
    @Published var loginSame = false
    @Published var liveCodex: LiveIdentity?
    @Published var codexKeyring = false
    @Published var provider: Provider = Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .claude {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "provider")
            Theme.current = provider
            if route != .list { cancelRoute() }
            onChange?()
        }
    }
    @Published var desktopOwner: String?
    @Published var desktopSaved: Set<String> = []
    @Published var desktopBusy = false
    @Published var syncDesktop: Bool = UserDefaults.standard.object(forKey: "syncDesktop") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncDesktop, forKey: "syncDesktop") }
    }

    var onChange: (() -> Void)?
    var loginTask: Task<Void, Never>?
    private var loginProc: LoginProcess?
    var loginExpect: Account?
    var codexLogin: CodexLogin?
    private var toastTask: Task<Void, Never>?
    /// --demo：只在内存里演示，所有会写钥匙串 / 配置文件的操作都不执行
    private(set) var demo = false
    private var timer: Timer?
    private var retryCount = 0

    // MARK: 派生状态

    func liveFor(_ p: Provider) -> LiveIdentity? { p == .claude ? live : liveCodex }
    var currentLive: LiveIdentity? { liveFor(provider) }
    func isActive(_ a: Account) -> Bool {
        if a.api != nil { return apiActive == a.id }
        if a.provider == .claude, apiActive != nil { return false }   // API 的 env 优先于 OAuth 登录
        return liveFor(a.provider)?.uuid == a.uuid
    }

    /// 当前 provider 下的账号
    var shown: [Account] { accounts.filter { $0.provider == provider } }
    func count(_ p: Provider) -> Int { accounts.filter { $0.provider == p }.count }

    var activeAccount: Account? { shown.first(where: isActive) }
    var unsavedLive: LiveIdentity? {
        guard let l = currentLive, !shown.contains(where: { $0.uuid == l.uuid }) else { return nil }
        return l
    }
    var others: [Account] { shown.filter { $0.id != activeAccount?.id } }

    /// 其他账号里 5 小时额度最充裕的那个
    var bestOtherID: String? {
        others.compactMap { a in usage[a.id]?.session.map { (a.id, $0.remaining) } }
            .max { $0.1 < $1.1 }
            .flatMap { $0.1 > 0 ? $0.0 : nil }
    }

    // MARK: 生命周期

    /// --demo：示例数据，不碰钥匙串和网络，仅用于验证界面
    private func startDemo() {
        demo = true
        func acc(_ n: String, _ e: String, _ plan: String) -> Account {
            Account(id: n, name: n, email: e, uuid: "u-" + n, plan: plan, oauth: .null, addedAt: Date().addingTimeInterval(Double(n.count)))
        }
        accounts = [acc("work", "chen@company.com", "Max"), acc("personal", "chen@gmail.com", "Pro"),
                    acc("usa", "relay@privaterelay.appleid.com", "Pro"), acc("old", "old@example.com", "Pro")]
        live = LiveIdentity(uuid: "u-work", email: "chen@company.com", plan: "Max")
        let now = Date()
        func u(_ s: Double, _ sm: Double, _ w: Double, _ wh: Double) -> UsageInfo {
            UsageInfo(session: Meter(remaining: s, resetsAt: now.addingTimeInterval(sm * 60)),
                      weekly: Meter(remaining: w, resetsAt: now.addingTimeInterval(wh * 3600)), opus: nil, sonnet: nil, fetchedAt: now)
        }
        usage = ["work": u(64, 151, 22, 38), "personal": u(91, 280, 73, 120), "usa": u(8, 33, 41, 70)]
        status["old"] = .needsLogin
        desktopOwner = "work"; desktopSaved = ["personal"]
        func cx(_ n: String, _ e: String, _ plan: String) -> Account {
            Account(id: n, name: n, email: e, uuid: "cx-" + n, plan: plan, oauth: .null, addedAt: Date().addingTimeInterval(Double(n.count)), provider: .codex)
        }
        accounts += [cx("main", "chen@openai-demo.com", "Plus"), cx("team", "chen@team-demo.com", "Team")]
        liveCodex = LiveIdentity(uuid: "cx-main", email: "chen@openai-demo.com", plan: "Plus")
        usage["main"] = u(72, 190, 55, 96)
        usage["team"] = u(35, 80, 18, 40)
        if CommandLine.arguments.contains("--codex") { provider = .codex }
        accounts.append(Account(id: "relay-a", name: "relay-a", email: "api.relay-demo.com", uuid: "api-relay-a", plan: "API", oauth: .null,
                                addedAt: now.addingTimeInterval(9), api: APIConfig(baseURL: "https://api.relay-demo.com", opus: "claude-opus-relay", sonnet: "claude-sonnet-relay")))
        apiOK = ["relay-a"]
        lastUpdated = now
        onChange?()
    }

    /// demo 模式下拦截写操作；返回 true 表示已拦截
    private func blockedByDemo() -> Bool {
        if demo { say(L("演示模式：不执行写入操作", "Demo mode: write actions are disabled")) }
        return demo
    }

    func start() {
        if CommandLine.arguments.contains("--demo") { startDemo(); return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accounts = AccountStore.load()
        // 先展示上次缓存的额度，再在后台刷新
        let ids = Set(accounts.map(\.id))
        usage = AccountStore.loadUsage().filter { ids.contains($0.key) }
        lastUpdated = usage.values.map(\.fetchedAt).max()
        live = ClaudeLive.identity()
        liveCodex = CodexLive.identity()
        Theme.current = provider
        reloadDesktop()
        Task {
            await refreshAllNow()
        }
        scheduleTimer()
        checkUpdate()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkUpdate() }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard refreshInterval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshInterval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func checkUpdate() {
        Task { if let u = await Updater.check() { update = u } }
    }

    /// 菜单里的「检查更新」：给出明确反馈
    func checkUpdateManually() {
        say(L("正在检查更新…", "Checking for updates…"))
        Task {
            if let u = await Updater.check() {
                update = u
                say(L("发现新版本 v\(u.version)，点击右上角「更新」即可升级", "New version v\(u.version) available. Click Update at the top right to upgrade"))
            } else {
                say(L("已是最新版本 v\(Updater.currentVersion)", "You are on the latest version (v\(Updater.currentVersion))"))
            }
        }
    }

    func installUpdate() {
        guard let u = update, !updating else { return }
        updating = true
        Task {
            do {
                try await Updater.install(u)
                NSApp.terminate(nil)
            } catch {
                updating = false
                say(L("更新失败：\(error.localizedDescription)", "Update failed: \(error.localizedDescription)"))
            }
        }
    }

    func reloadLive() {
        live = ClaudeLive.identity()
        liveCodex = CodexLive.identity()
        apiActive = ClaudeLive.activeAPIID()
        onChange?()
    }

    /// 打开面板：只刷新本地身份；额度数据超过 2 分钟才在后台刷新，否则直接用缓存
    func refreshIfStale() {
        reloadLive()
        let staleAfter = refreshInterval > 0 ? min(120, TimeInterval(refreshInterval)) : 120
        if lastUpdated == nil || Date().timeIntervalSince(lastUpdated!) > staleAfter { refreshAll() }
    }

    func refreshAll() { Task { await refreshAllNow() } }

    func refreshManually() {
        manualRefreshing = true
        refreshAll()
    }

    func refreshAllNow() async {
        guard !refreshing, !demo else { manualRefreshing = false; return }
        refreshing = true
        defer {
            refreshing = false
            manualRefreshing = false
            lastUpdated = Date()
            onChange?()
            scheduleRetryIfNeeded()
        }
        accounts = await AccountStore.syncLive(into: accounts)
        accounts = await AccountStore.syncLiveCodex(into: accounts)
        reloadLive()
        codexKeyring = await CodexLive.usesKeyringOnly()
        let targets = accounts
        let activeIDs = Set(targets.filter(isActive).map(\.id))
        for a in targets where usage[a.id] == nil && a.api == nil { status[a.id] = .loading }
        // 逐个串行请求：避免多账号并发打接口（限流）和并发刷新同一份凭证
        for a in targets {
            if a.api != nil {
                let st = await APIService.check(a)
                status[a.id] = st
                if st == nil { apiOK.insert(a.id) } else { apiOK.remove(a.id) }
                onChange?()
                continue
            }
            let active = activeIDs.contains(a.id)
            let out = a.provider == .codex ? await CodexService.load(a, isActive: active) : await UsageService.load(a, isActive: active)
            switch out {
            case .ok(let u): usage[a.id] = u; status[a.id] = nil
            case .needsLogin: status[a.id] = .needsLogin
            case .failed(let m): status[a.id] = .error(m)
            }
            onChange?()
        }
        AccountStore.saveUsage(usage)
    }

    /// 有账号因网络问题失败时，20 秒后自动再试，最多连续 3 次
    private func scheduleRetryIfNeeded() {
        let failed = status.values.contains { if case .error = $0 { return true }; return false }
        guard failed, retryCount < 3 else { if !failed { retryCount = 0 }; return }
        retryCount += 1
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await refreshAllNow()
        }
    }

    func say(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: 切换

    func switchTo(_ acc: Account) {
        guard switching == nil, !isActive(acc), !blockedByDemo() else { return }
        switching = acc.id
        Task {
            do {
                if acc.api != nil {
                    accounts = try await AccountStore.switchToAPI(acc, accounts: accounts)
                } else {
                    accounts = acc.provider == .codex ? try await AccountStore.switchToCodex(acc, accounts: accounts)
                                                      : try await AccountStore.switchTo(acc, accounts: accounts)
                }
                reloadLive()
                let wasAPI = acc.api != nil
                var note = acc.provider == .codex ? L("新会话立即生效，已打开的 Codex 需重启", "Effective for new sessions; restart any open Codex") : L("新会话立即生效，IDE 需重启", "Effective for new sessions; restart your IDE")
                if wasAPI { note = L("新会话立即生效，IDE 需重启（Claude 桌面端不受影响）", "Effective for new sessions; restart your IDE (Claude Desktop is unaffected)") }
                else if acc.provider == .claude, syncDesktop, ClaudeDesktop.installed, desktopSaved.contains(acc.id) || desktopOwner == acc.id {
                    if desktopOwner != acc.id { note = await switchDesktop(acc, quiet: true) ? L("桌面端已同步，", "Desktop synced. ") + note : note }
                }
                say(L("已切换到 \(acc.name) · \(note)", "Switched to \(acc.name) · \(note)"))
                await refreshAllNow()
            } catch {
                say(error.localizedDescription)
            }
            switching = nil
        }
    }

    // MARK: 添加：保存当前登录会话

    func beginSaveCurrent() {
        guard let l = currentLive else { say(L("当前没有 \(provider.title) 登录会话", "No \(provider.title) login session found")); return }
        draftName = AccountStore.suggestName(email: l.email, existing: accounts)
        formError = nil
        route = .save
    }

    func beginAddAPI() {
        draftName = ""; draftBaseURL = ""; draftKey = ""; draftModel = ""; draftSubagent = ""; draftOpus = ""; draftSonnet = ""; draftHaiku = ""
        apiModels = []; modelsError = nil
        formError = nil
        route = .addAPI
    }

    func beginEditAPI(_ a: Account) {
        guard let api = a.api else { return }
        draftName = a.name; draftBaseURL = api.baseURL; draftKey = ""
        draftModel = api.model; draftSubagent = api.subagent; draftOpus = api.opus; draftSonnet = api.sonnet; draftHaiku = api.haiku
        apiModels = []; modelsError = nil
        formError = nil
        route = .editAPI(a.id)
        fetchModels()
    }

    /// 用表单里的 Base URL + 密钥拉模型列表；编辑时密钥留空则用已保存的
    func fetchModels() {
        guard !modelsLoading else { return }
        var editID: String?
        if case .editAPI(let i) = route { editID = i }
        modelsError = nil
        Task {
            var key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty, let editID { key = await Vault.shared.get(editID) ?? "" }
            guard !key.isEmpty else { modelsError = L("请先输入 API 密钥", "Enter the API key first"); return }
            modelsLoading = true
            defer { modelsLoading = false }
            do {
                apiModels = try await APIService.fetchModels(baseURL: try AccountStore.normalizeURL(draftBaseURL), key: key)
            } catch {
                apiModels = []
                modelsError = error.localizedDescription
            }
        }
    }

    func beginRename(_ a: Account) {
        draftName = a.name
        formError = nil
        route = .rename(a.id)
    }

    func confirmForm() {
        guard !blockedByDemo() else { return }
        Task {
            do {
                switch route {
                case .save:
                    let acc = provider == .codex ? try await AccountStore.addCurrentCodex(name: draftName, existing: accounts)
                                                 : try await AccountStore.addCurrent(name: draftName, existing: accounts)
                    accounts.append(acc)
                    say(L("已添加账号 \(acc.name)", "Added account \(acc.name)"))
                case .addAPI, .editAPI:
                    var id: String?
                    if case .editAPI(let i) = route { id = i }
                    let cfg = APIConfig(baseURL: draftBaseURL, model: draftModel, opus: draftOpus, sonnet: draftSonnet, haiku: draftHaiku, subagent: draftSubagent)
                    accounts = try await AccountStore.saveAPI(id: id, name: draftName, config: cfg, key: draftKey, existing: accounts)
                    // 正在使用的 API 账号被编辑：立刻把新配置写进 settings.json
                    if let id, apiActive == id, let acc = accounts.first(where: { $0.id == id }),
                       let key = await Vault.shared.get(id) {
                        try ClaudeLive.applyAPI(acc, key: key)
                    }
                    say(id == nil ? L("已添加 API 账号 \(draftName)", "Added API account \(draftName)") : L("已保存", "Saved"))
                    status = status.filter { $0.key != id }
                case .rename(let id):
                    accounts = try AccountStore.rename(id, to: draftName, in: accounts)
                default: return
                }
                route = .list
                draftKey = ""
                await refreshAllNow()
            } catch {
                formError = error.localizedDescription
            }
        }
    }

    // MARK: 添加 / 重新登录（终端执行 claude auth login，完成后自动保存）

    /// expect != nil：为已有账号重新登录。
    /// 在独立配置目录 + 伪终端里运行 `claude auth login`，完成后把新凭证存成账号；全程不改动当前 Claude 登录。
    func beginLogin(expect: Account? = nil) {
        if (expect?.provider ?? provider) == .codex { beginCodexLogin(expect: expect); return }
        route = .waitingLogin
        loginURL = nil
        loginNote = nil
        loginSame = false
        loginExpect = expect
        loginTask?.cancel()
        loginProc?.terminate()
        let proc = LoginProcess()
        loginProc = proc
        loginTask = Task {
            guard let exe = await ClaudeCLI.executable() else {
                loginNote = L("没有找到 claude 命令行，请先安装 Claude Code", "The claude command was not found. Please install Claude Code first")
                await proc.cleanup()
                return
            }
            let exitBox = ExitBox()
            do {
                try proc.start(executable: exe, email: expect?.email) { code, tail in exitBox.set(code, tail) }
            } catch {
                loginNote = L("无法启动 claude：\(error.localizedDescription)", "Could not launch claude: \(error.localizedDescription)")
                await proc.cleanup()
                return
            }
            for _ in 0..<1500 {   // 最长 7.5 分钟
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { await proc.cleanup(); return }
                if loginURL == nil { loginURL = proc.authorizeURL() }
                if let (code, tail) = exitBox.get() {
                    await finishLogin(proc, code: code, tail: tail, expect: expect)
                    return
                }
            }
            loginNote = L("登录超时，请重试", "Login timed out. Please try again")
            await proc.cleanup()
        }
    }

    private func finishLogin(_ proc: LoginProcess, code: Int32, tail: String, expect: Account?) async {
        defer { Task { await proc.cleanup() } }
        guard code == 0 || proc.succeeded else {
            loginNote = tail.isEmpty ? L("登录进程已退出（\(code)）", "The login process exited (\(code))") : tail
            return
        }
        guard let cred = await Keychain.read(service: proc.keychainService), let oauth = proc.oauthAccount(),
              let uuid = oauth["accountUuid"]?.string else {
            loginNote = L("登录完成，但没能读到新账号的凭证，请重试", "Login finished, but the new account's credentials could not be read. Please try again")
            return
        }
        let email = oauth["emailAddress"]?.string ?? ""
        do {
            if let known = accounts.first(where: { $0.uuid == uuid }) {
                if expect != nil && expect?.id != known.id {
                    loginNote = L("登录的是 \(email)，不是要重新登录的账号，请重试", "You logged in as \(email), which is not the account to re-login. Please try again")
                } else if expect != nil {
                    accounts = try await AccountStore.replaceCredential(known, cred: cred, oauth: oauth, in: accounts)
                    status[known.id] = nil
                    route = .list
                    say(L("\(known.name) 已重新登录", "\(known.name) has been logged in again"))
                    await refreshAllNow()
                } else {
                    loginSame = true
                    loginNote = L("登录的是「\(known.name)」（\(email)），已经在列表里了，没有新账号。\n请先在浏览器里退出当前账号，或换用其他浏览器打开链接，再重试。", "You logged in as \"\(known.name)\" (\(email)), which is already in the list, so no new account was added.\nSign out in the browser first, or open the link in another browser, then try again.")
                }
                return
            }
            if let exp = expect {
                loginNote = L("登录的是 \(email)，不是「\(exp.name)」（\(exp.email)），请重试", "You logged in as \(email), not \"\(exp.name)\" (\(exp.email)). Please try again")
                return
            }
            let name = AccountStore.suggestName(email: email, existing: accounts)
            let acc = try await AccountStore.add(name: name, cred: cred, oauth: oauth, existing: accounts)
            accounts.append(acc)
            route = .list
            say(L("已添加 \(acc.name)，当前登录未改变", "Added \(acc.name). Your current login is unchanged"))
            await refreshAllNow()
        } catch {
            loginNote = error.localizedDescription
        }
    }

    func openLoginURL() {
        guard let u = loginURL, let url = URL(string: u) else { return }
        NSWorkspace.shared.open(url)
    }

    func retryLogin() { beginLogin(expect: loginExpect) }

    func copyLoginURL() {
        guard let u = loginURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u, forType: .string)
        say(L("授权链接已复制", "Authorization link copied"))
    }

    func cancelRoute() {
        codexLogin?.cancel()
        codexLogin = nil
        loginTask?.cancel()
        loginProc?.terminate()
        formError = nil
        draftKey = ""
        route = .list
    }

    func remove(_ acc: Account) {
        guard !blockedByDemo() else { return }
        Task {
            do {
                if acc.api != nil, apiActive == acc.id { try ClaudeLive.clearAPI(); reloadLive() }
                accounts = try await AccountStore.remove(acc, from: accounts)
                apiOK.remove(acc.id)
                if acc.provider == .claude { ClaudeDesktop.forget(acc.id); reloadDesktop() }
                usage[acc.id] = nil
                status[acc.id] = nil
                onChange?()
                say(L("已移除 \(acc.name)（当前 \(acc.provider.title) 登录不受影响）", "Removed \(acc.name) (your current \(acc.provider.title) login is unaffected)"))
            } catch { say(error.localizedDescription) }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            say(L("设置开机启动失败：\(error.localizedDescription)", "Failed to set launch at login: \(error.localizedDescription)"))
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// 子进程退出信息的线程安全盒子
final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int32, String)?
    func set(_ code: Int32, _ tail: String) { lock.lock(); value = (code, tail); lock.unlock() }
    func get() -> (Int32, String)? { lock.lock(); defer { lock.unlock() }; return value }
}

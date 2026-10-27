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
}

@MainActor
final class AppModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var live: LiveIdentity?
    @Published var usage: [String: UsageInfo] = [:]
    @Published var status: [String: AccountStatus] = [:]
    @Published var route: Route = .list
    @Published var draftName = ""
    @Published var formError: String?
    @Published var toast: String?
    @Published var update: UpdateInfo?
    @Published var updating = false
    @Published var switching: String?
    @Published var refreshing = false
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
    private var timer: Timer?
    private var retryCount = 0

    // MARK: 派生状态

    func liveFor(_ p: Provider) -> LiveIdentity? { p == .claude ? live : liveCodex }
    var currentLive: LiveIdentity? { liveFor(provider) }
    func isActive(_ a: Account) -> Bool { liveFor(a.provider)?.uuid == a.uuid }

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
        lastUpdated = now
        onChange?()
    }

    func start() {
        if CommandLine.arguments.contains("--demo") { startDemo(); return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accounts = AccountStore.load()
        live = ClaudeLive.identity()
        liveCodex = CodexLive.identity()
        Theme.current = provider
        reloadDesktop()
        Task {
            await refreshAllNow()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        checkUpdate()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkUpdate() }
        }
    }

    func checkUpdate() {
        Task { if let u = await Updater.check() { update = u } }
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
                say("更新失败：\(error.localizedDescription)")
            }
        }
    }

    func reloadLive() {
        live = ClaudeLive.identity()
        liveCodex = CodexLive.identity()
        onChange?()
    }

    func refreshIfStale() {
        reloadLive()
        if lastUpdated == nil || Date().timeIntervalSince(lastUpdated!) > 30 { refreshAll() }
    }

    func refreshAll() { Task { await refreshAllNow() } }

    func refreshAllNow() async {
        guard !refreshing else { return }
        refreshing = true
        defer {
            refreshing = false
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
        for a in targets where usage[a.id] == nil { status[a.id] = .loading }
        await withTaskGroup(of: (String, UsageOutcome).self) { group in
            for a in targets {
                let active = activeIDs.contains(a.id)
                group.addTask {
                    (a.id, a.provider == .codex ? await CodexService.load(a, isActive: active) : await UsageService.load(a, isActive: active))
                }
            }
            for await (id, out) in group {
                switch out {
                case .ok(let u): usage[id] = u; status[id] = nil
                case .needsLogin: status[id] = .needsLogin
                case .failed(let m): status[id] = .error(m)
                }
                onChange?()
            }
        }
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
        guard switching == nil, !isActive(acc) else { return }
        switching = acc.id
        Task {
            do {
                accounts = acc.provider == .codex ? try await AccountStore.switchToCodex(acc, accounts: accounts)
                                                  : try await AccountStore.switchTo(acc, accounts: accounts)
                reloadLive()
                var note = acc.provider == .codex ? "新会话立即生效，已打开的 Codex 需重启" : "新会话立即生效，IDE 需重启"
                if acc.provider == .claude, syncDesktop, ClaudeDesktop.installed, desktopSaved.contains(acc.id) || desktopOwner == acc.id {
                    if desktopOwner != acc.id { note = await switchDesktop(acc, quiet: true) ? "桌面端已同步，" + note : note }
                }
                say("已切换到 \(acc.name) · \(note)")
                await refreshAllNow()
            } catch {
                say(error.localizedDescription)
            }
            switching = nil
        }
    }

    // MARK: 添加：保存当前登录会话

    func beginSaveCurrent() {
        guard let l = currentLive else { say("当前没有 \(provider.title) 登录会话"); return }
        draftName = AccountStore.suggestName(email: l.email, existing: accounts)
        formError = nil
        route = .save
    }

    func beginRename(_ a: Account) {
        draftName = a.name
        formError = nil
        route = .rename(a.id)
    }

    func confirmForm() {
        Task {
            do {
                switch route {
                case .save:
                    let acc = provider == .codex ? try await AccountStore.addCurrentCodex(name: draftName, existing: accounts)
                                                 : try await AccountStore.addCurrent(name: draftName, existing: accounts)
                    accounts.append(acc)
                    say("已添加账号 \(acc.name)")
                case .rename(let id):
                    accounts = try AccountStore.rename(id, to: draftName, in: accounts)
                default: return
                }
                route = .list
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
                loginNote = "没有找到 claude 命令行，请先安装 Claude Code"
                await proc.cleanup()
                return
            }
            let exitBox = ExitBox()
            do {
                try proc.start(executable: exe, email: expect?.email) { code, tail in exitBox.set(code, tail) }
            } catch {
                loginNote = "无法启动 claude：\(error.localizedDescription)"
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
            loginNote = "登录超时，请重试"
            await proc.cleanup()
        }
    }

    private func finishLogin(_ proc: LoginProcess, code: Int32, tail: String, expect: Account?) async {
        defer { Task { await proc.cleanup() } }
        guard code == 0 || proc.succeeded else {
            loginNote = tail.isEmpty ? "登录进程已退出（\(code)）" : tail
            return
        }
        guard let cred = await Keychain.read(service: proc.keychainService), let oauth = proc.oauthAccount(),
              let uuid = oauth["accountUuid"]?.string else {
            loginNote = "登录完成，但没能读到新账号的凭证，请重试"
            return
        }
        let email = oauth["emailAddress"]?.string ?? ""
        do {
            if let known = accounts.first(where: { $0.uuid == uuid }) {
                if expect != nil && expect?.id != known.id {
                    loginNote = "登录的是 \(email)，不是要重新登录的账号，请重试"
                } else if expect != nil {
                    accounts = try await AccountStore.replaceCredential(known, cred: cred, oauth: oauth, in: accounts)
                    status[known.id] = nil
                    route = .list
                    say("\(known.name) 已重新登录")
                    await refreshAllNow()
                } else {
                    loginSame = true
                    loginNote = "登录的是「\(known.name)」（\(email)），已经在列表里了，没有新账号。\n请先在浏览器里退出当前账号，或换用其他浏览器打开链接，再重试。"
                }
                return
            }
            if let exp = expect {
                loginNote = "登录的是 \(email)，不是「\(exp.name)」（\(exp.email)），请重试"
                return
            }
            let name = AccountStore.suggestName(email: email, existing: accounts)
            let acc = try await AccountStore.add(name: name, cred: cred, oauth: oauth, existing: accounts)
            accounts.append(acc)
            route = .list
            say("已添加 \(acc.name)，当前登录未改变")
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
        say("授权链接已复制")
    }

    func cancelRoute() {
        codexLogin?.cancel()
        codexLogin = nil
        loginTask?.cancel()
        loginProc?.terminate()
        formError = nil
        route = .list
    }

    func remove(_ acc: Account) {
        Task {
            do {
                accounts = try await AccountStore.remove(acc, from: accounts)
                if acc.provider == .claude { ClaudeDesktop.forget(acc.id); reloadDesktop() }
                usage[acc.id] = nil
                status[acc.id] = nil
                onChange?()
                say("已移除 \(acc.name)（当前 \(acc.provider.title) 登录不受影响）")
            } catch { say(error.localizedDescription) }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            say("设置开机启动失败：\(error.localizedDescription)")
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

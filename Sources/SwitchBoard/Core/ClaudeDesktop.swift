import Foundation
import AppKit

/// Claude 桌面端（Electron）的账号切换。
/// 桌面端的登录态散落在 ~/Library/Application Support/Claude 整个目录里（加密的 token 缓存、Cookies、本地存储），
/// 所以按账号各存一份整目录快照：切换 = 退出桌面端 → 把当前目录收进「当前持有者」的槽 → 把目标槽换到原位 → 重新打开。
/// 加密密钥（钥匙串里的 Claude Safe Storage）是整机共用的，各份快照互相可用，所以这里完全不读钥匙串。
enum ClaudeDesktop {
    static let bundleID = "com.anthropic.claudefordesktop"

    static var dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Claude")
    static var slotsDir = AccountStore.dir.appendingPathComponent("desktop")
    static var stateFile = AccountStore.dir.appendingPathComponent("desktop.json")

    /// owner：现在摆在原位的那份桌面端数据属于哪个账号（nil = 还没绑定）
    struct State: Codable { var owner: String? }

    static func loadState() -> State {
        guard let d = try? Data(contentsOf: stateFile), let s = try? JSONDecoder().decode(State.self, from: d) else { return State() }
        return s
    }

    static func saveState(_ s: State) throws {
        try FileManager.default.createDirectory(at: AccountStore.dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(s).write(to: stateFile, options: .atomic)
    }

    static func slot(_ id: String) -> URL { slotsDir.appendingPathComponent(id) }

    /// 已经存了快照的账号
    static func savedIDs() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: slotsDir.path)) ?? []
        return Set(names.filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") })
    }

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var installed: Bool { appURL != nil }

    // MARK: 文件层（纯文件操作，不碰进程，便于验证）

    /// 把原位的数据收进当前持有者的槽，再把 target 的槽换到原位（target 没有快照则原位留空，桌面端启动后是全新登录界面）。
    /// 同一卷上的 rename 是原子的；第二步失败会把第一步还原。
    static func swapFiles(to target: String?) throws {
        var state = loadState()
        guard state.owner != target else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: slotsDir, withIntermediateDirectories: true)

        var parked: URL?
        if fm.fileExists(atPath: dataDir.path) {
            let name = state.owner ?? "_unassigned-\(Int(Date().timeIntervalSince1970))"
            let dest = slot(name)
            guard !fm.fileExists(atPath: dest.path) else { throw AppError(L("桌面端快照位置已被占用：\(dest.lastPathComponent)", "The Claude Desktop snapshot location is already in use: \(dest.lastPathComponent)")) }
            try fm.moveItem(at: dataDir, to: dest)
            parked = dest
        }
        if let target, fm.fileExists(atPath: slot(target).path) {
            do { try fm.moveItem(at: slot(target), to: dataDir) }
            catch {
                if let parked { try? fm.moveItem(at: parked, to: dataDir) }
                throw error
            }
        }
        state.owner = target
        try saveState(state)
    }

    /// 把当前原位的桌面端登录认领给某账号（不移动任何文件）
    static func bindCurrent(to id: String) throws {
        try? FileManager.default.trashItem(at: slot(id), resultingItemURL: nil)
        try saveState(State(owner: id))
    }

    /// 账号被移除：清掉它的快照与绑定
    static func forget(_ id: String) {
        try? FileManager.default.trashItem(at: slot(id), resultingItemURL: nil)
        var s = loadState()
        if s.owner == id { s.owner = nil; try? saveState(s) }
    }

    // MARK: 进程层

    /// 退出桌面端；返回之前是否在运行。8 秒内没退出就强制结束。
    @MainActor
    static func quit() async throws -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else { return false }
        apps.forEach { $0.terminate() }
        if await !waitExit(apps, seconds: 8) {
            apps.forEach { $0.forceTerminate() }
            if await !waitExit(apps, seconds: 4) { throw AppError(L("Claude 桌面端没有退出，请手动退出后重试", "Claude Desktop did not quit. Please quit it manually and try again")) }
        }
        return true
    }

    @MainActor
    private static func waitExit(_ apps: [NSRunningApplication], seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if apps.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return apps.allSatisfy(\.isTerminated)
    }

    @MainActor
    static func launch() {
        guard let url = appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 完整流程：退出 → 换目录 → （之前在运行或 forceLaunch 时）重新打开
    @MainActor
    static func switchOwner(to id: String, forceLaunch: Bool = false) async throws {
        guard installed else { throw AppError(L("没有找到 Claude 桌面端（Claude.app）", "Claude Desktop (Claude.app) was not found")) }
        let wasRunning = try await quit()
        try swapFiles(to: id)
        if wasRunning || forceLaunch { launch() }
    }
}

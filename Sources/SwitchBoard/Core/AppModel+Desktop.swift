import Foundation

extension AppModel {
    func reloadDesktop() {
        desktopOwner = ClaudeDesktop.loadState().owner
        desktopSaved = ClaudeDesktop.savedIDs()
    }

    /// 桌面端状态：使用中 / 已保存 / 无
    func desktopMark(_ acc: Account) -> DesktopMark {
        if desktopOwner == acc.id { return .active }
        return desktopSaved.contains(acc.id) ? .saved : .none
    }

    /// 切换桌面端到某账号（需要它已有快照）。quiet = 由「切换账号」联动调用，失败时不单独弹 toast
    @discardableResult
    func switchDesktop(_ acc: Account, quiet: Bool = false, forceLaunch: Bool = true) async -> Bool {
        guard !desktopBusy else { return false }
        desktopBusy = true
        defer { desktopBusy = false }
        do {
            try await ClaudeDesktop.switchOwner(to: acc.id, forceLaunch: forceLaunch)
            reloadDesktop()
            if !quiet { say(L("Claude 桌面端已切换到 \(acc.name)", "Claude Desktop switched to \(acc.name)")) }
            return true
        } catch {
            reloadDesktop()
            say(L("桌面端切换失败：\(error.localizedDescription)", "Failed to switch Claude Desktop: \(error.localizedDescription)"))
            return false
        }
    }

    /// 把桌面端当前的登录认领给该账号
    func bindDesktop(_ acc: Account) {
        do {
            try ClaudeDesktop.bindCurrent(to: acc.id)
            reloadDesktop()
            say(L("已把 Claude 桌面端当前登录绑定到 \(acc.name)", "Bound the current Claude Desktop login to \(acc.name)"))
        } catch { say(L("绑定失败：\(error.localizedDescription)", "Binding failed: \(error.localizedDescription)")) }
    }

    /// 为没有快照的账号新登录桌面端：把现有桌面端数据收起来，打开一个全新的登录界面
    func loginDesktopFresh(_ acc: Account) {
        Task {
            guard !desktopBusy else { return }
            desktopBusy = true
            defer { desktopBusy = false }
            do {
                try await ClaudeDesktop.switchOwner(to: acc.id, forceLaunch: true)
                reloadDesktop()
                say(L("请在 Claude 桌面端登录 \(acc.email.isEmpty ? acc.name : acc.email)，登录后会自动归到该账号", "Log in to Claude Desktop as \(acc.email.isEmpty ? acc.name : acc.email); it will be linked to this account automatically"))
            } catch { reloadDesktop(); say(L("桌面端操作失败：\(error.localizedDescription)", "Claude Desktop operation failed: \(error.localizedDescription)")) }
        }
    }

    func unbindDesktop(_ acc: Account) {
        ClaudeDesktop.forget(acc.id)
        reloadDesktop()
        say(L("已解除 \(acc.name) 的桌面端绑定", "Unbound Claude Desktop from \(acc.name)"))
    }
}

enum DesktopMark { case active, saved, none }

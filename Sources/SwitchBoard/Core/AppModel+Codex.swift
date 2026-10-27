import Foundation

extension AppModel {
    /// Codex 登录：应用内 OAuth（不依赖 codex 命令行）。链接立即可用，由界面上的按钮决定何时打开。
    func beginCodexLogin(expect: Account?) {
        route = .waitingLogin
        loginNote = nil
        loginSame = false
        loginExpect = expect
        cancelLoginWork()
        let login = CodexLogin()
        codexLogin = login
        loginURL = login.authorizeURL
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 450_000_000_000)
            if !Task.isCancelled { loginNote = L("登录超时，请重试", "Login timed out. Please try again"); login.cancel() }
        }
        loginTask = Task {
            defer { timeout.cancel() }
            do {
                let auth = try await login.run()
                await finishCodexLogin(auth, expect: expect)
            } catch is CancellationError {
            } catch {
                loginNote = error.localizedDescription
            }
        }
    }

    private func finishCodexLogin(_ auth: String, expect: Account?) async {
        guard let id = CodexLive.identity(of: auth) else { loginNote = L("登录完成，但没能读到账号信息，请重试", "Login finished, but the account information could not be read. Please try again"); return }
        let known = accounts.first { $0.provider == .codex && $0.uuid == id.uuid }
        do {
            if let known {
                if expect != nil && expect?.id != known.id {
                    loginNote = L("登录的是 \(id.email)，不是要重新登录的账号，请重试", "You logged in as \(id.email), which is not the account to re-login. Please try again")
                } else if expect != nil {
                    accounts = try await AccountStore.replaceCodexCredential(known, auth: auth, in: accounts)
                    if isActive(known) { try? CodexLive.writeAuth(auth) }
                    status[known.id] = nil
                    route = .list
                    say(L("\(known.name) 已重新登录", "\(known.name) has been logged in again"))
                    await refreshAllNow()
                } else {
                    loginSame = true
                    loginNote = L("登录的是「\(known.name)」（\(id.email)），已经在列表里了，没有新账号。\n请在浏览器的登录页选择其他账号，再重试。", "You logged in as \"\(known.name)\" (\(id.email)), which is already in the list, so no new account was added.\nPick a different account on the browser login page and try again.")
                }
                return
            }
            if let exp = expect {
                loginNote = L("登录的是 \(id.email)，不是「\(exp.name)」（\(exp.email)），请重试", "You logged in as \(id.email), not \"\(exp.name)\" (\(exp.email)). Please try again")
                return
            }
            let name = AccountStore.suggestName(email: id.email, existing: accounts)
            let acc = try await AccountStore.addCodex(name: name, auth: auth, existing: accounts)
            accounts.append(acc)
            route = .list
            say(L("已添加 \(acc.name)，当前 Codex 登录未改变", "Added \(acc.name). Your current Codex login is unchanged"))
            await refreshAllNow()
        } catch {
            loginNote = error.localizedDescription
        }
    }

    private func cancelLoginWork() {
        codexLogin?.cancel()
        loginTask?.cancel()
    }
}

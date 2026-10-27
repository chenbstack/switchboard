import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            HeaderBar(model: model)

            switch model.route {
            case .list:
                if model.shown.isEmpty && model.unsavedLive == nil { EmptyState(provider: model.provider) }
                ForEach(model.shown) { acc in
                    AccountCard(model: model, acc: acc, isBest: model.bestOtherID == acc.id)
                }
                if let l = model.unsavedLive { UnsavedCard(model: model, live: l) }
                if model.provider == .codex, model.codexKeyring { KeyringNotice() }
                AddBar(model: model)
            case .save, .rename:
                NameForm(model: model)
            case .waitingLogin:
                WaitingLogin(model: model)
            }

            FooterBar(model: model)
        }
        .padding(16)
        .animation(.spring(response: 0.4, dampingFraction: 0.84), value: model.accounts)
        .animation(.spring(response: 0.4, dampingFraction: 0.84), value: model.route)
        .animation(.spring(response: 0.4, dampingFraction: 0.84), value: model.live)
        .animation(.spring(response: 0.4, dampingFraction: 0.84), value: model.provider)
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
                    .padding(.horizontal, 20).padding(.bottom, 48)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.toast)
        .preferredColorScheme(.dark)
    }
}

// MARK: 头部

struct UpdateButton: View {
    let version: String
    let busy: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if busy { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                else { Image(systemName: "arrow.down.circle.fill").font(.system(size: 11, weight: .bold)) }
                Text(busy ? "更新中" : "更新").font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).frame(height: 26)
            .background(LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .leading, endPoint: .trailing), in: Capsule())
            .shadow(color: Theme.accent.opacity(0.4), radius: 6, y: 1)
        }
        .buttonStyle(.plain).disabled(busy)
        .help("发现新版本 v\(version)，点击更新并重启")
    }
}

struct HeaderBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(Provider.allCases) { p in
                    Button { model.provider = p } label: {
                        Label("\(p.title) · \(model.count(p)) 个账号", systemImage: model.provider == p ? "checkmark" : p.symbol)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: model.provider.symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 28, height: 28)
                    .shadow(color: Theme.accent.opacity(0.45), radius: 8, y: 2)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(model.provider.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text1)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text2)
                        }
                        Text(model.shown.isEmpty ? "尚未添加账号" : "\(model.shown.count) 个账号")
                            .font(.system(size: 11)).foregroundStyle(Theme.text2)
                    }
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer()
            if let u = model.update { UpdateButton(version: u.version, busy: model.updating) { model.installUpdate() } }
            IconButton(symbol: "arrow.clockwise", spinning: model.refreshing) { model.refreshAll() }
            Menu {
                Toggle("开机启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if ClaudeDesktop.installed, model.provider == .claude {
                    Toggle("切换账号时同步 Claude 桌面端", isOn: $model.syncDesktop)
                }
                Divider()
                Button("退出 SwitchBoard") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text2)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
        .padding(.horizontal, 2)
    }
}

// MARK: 账号卡片（所有账号同一种样式，当前账号用边框 + 背景色标识）

struct AccountCard: View {
    @ObservedObject var model: AppModel
    let acc: Account
    let isBest: Bool
    @State private var hover = false
    @State private var confirmDelete = false

    var isActive: Bool { model.isActive(acc) }
    var usage: UsageInfo? { model.usage[acc.id] }
    var status: AccountStatus? { model.status[acc.id] }
    var busy: Bool { model.switching == acc.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                Avatar(key: acc.uuid, label: acc.name, size: 36, glow: isActive)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(acc.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        PlanPill(text: acc.planLabel)
                        if acc.provider == .claude { DesktopChip(mark: model.desktopMark(acc)) }
                    }
                    Text(acc.email).font(.system(size: 11)).foregroundStyle(Theme.text2)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                trailing
            }
            body_
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isActive ? Theme.accent.opacity(0.15) : .white.opacity(hover ? 0.07 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(isActive ? Theme.accent : .white.opacity(hover ? 0.14 : 0.08),
                          lineWidth: isActive ? 1.5 : 0.8))
        .shadow(color: isActive ? Theme.accent.opacity(0.35) : .clear, radius: 16)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { if !isActive, status != .needsLogin, !confirmDelete { model.switchTo(acc) } }
        .onHover { hover = $0; if !$0 { confirmDelete = false } }
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.spring(response: 0.4, dampingFraction: 0.84), value: isActive)
        .contextMenu { AccountMenu(model: model, acc: acc) }
    }

    @ViewBuilder var trailing: some View {
        if isActive {
            HStack(spacing: 5) {
                Circle().fill(Theme.good).frame(width: 6, height: 6).shadow(color: Theme.good.opacity(0.9), radius: 4)
                Text("使用中").font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.good.opacity(0.14), in: Capsule())
            .foregroundStyle(Theme.good)
        } else if confirmDelete {
            Button("确认移除") { model.remove(acc) }.buttonStyle(PillButton(fill: Theme.bad))
        } else if hover || busy {
            HStack(spacing: 6) {
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(PillButton(fill: .white.opacity(0.08), textColor: Theme.text2, compact: true))
                if status == .needsLogin {
                    Button("重新登录") { model.beginLogin(expect: acc) }.buttonStyle(PillButton(fill: Theme.accent))
                } else {
                    Button {
                        model.switchTo(acc)
                    } label: {
                        if busy { ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 24) } else { Text("切换") }
                    }
                    .buttonStyle(PillButton(fill: Theme.accent))
                }
            }
            .transition(.opacity)
        } else if isBest {
            Text("最空闲").font(.system(size: 10.5, weight: .bold))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Theme.good.opacity(0.16), in: Capsule()).foregroundStyle(Theme.good)
        }
    }

    @ViewBuilder var body_: some View {
        if let u = usage {
            VStack(spacing: 8) {
                if let m = u.session { MeterLine(title: "5 小时", meter: m) }
                if let m = u.weekly { MeterLine(title: "每周", meter: m) }
                if let m = u.opus { MeterLine(title: "Opus", meter: m) }
                if let m = u.sonnet { MeterLine(title: "Sonnet", meter: m) }
                if u.session == nil && u.weekly == nil {
                    Text("暂无额度数据").font(.system(size: 11)).foregroundStyle(Theme.text2)
                }
                if case .error(let m) = status {
                    Label(m, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(Theme.warn)
                }
            }
            if case .needsLogin = status { LoginHint(model: model, acc: acc) }
        } else {
            switch status {
            case .needsLogin: LoginHint(model: model, acc: acc)
            case .error(let m):
                Label(m, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warn)
            default: SkeletonLines()
            }
        }
    }
}

struct SkeletonLines: View {
    @State private var on = false
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08)).frame(width: 44, height: 9)
                    Capsule().fill(.white.opacity(0.08)).frame(height: 5)
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08)).frame(width: 90, height: 9)
                }
            }
        }
        .opacity(on ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
        .onAppear { on = true }
    }
}

struct LoginHint: View {
    @ObservedObject var model: AppModel
    let acc: Account
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.slash").foregroundStyle(Theme.warn)
            Text("登录已失效").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            Spacer()
            Button("重新登录") { model.beginLogin(expect: acc) }
                .buttonStyle(PillButton(fill: .white.opacity(0.14), textColor: Theme.text1, compact: true))
        }
        .padding(10)
        .background(Theme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct AccountMenu: View {
    @ObservedObject var model: AppModel
    let acc: Account
    var body: some View {
        Button("重命名…") { model.beginRename(acc) }
        Button("刷新额度") { model.refreshAll() }
        if acc.provider == .claude, ClaudeDesktop.installed {
            Divider()
            switch model.desktopMark(acc) {
            case .active:
                Button("解除桌面端绑定") { model.unbindDesktop(acc) }
            case .saved:
                Button("切换桌面端到此账号") { Task { await model.switchDesktop(acc) } }
                Button("解除桌面端绑定") { model.unbindDesktop(acc) }
            case .none:
                Button("把当前桌面端登录绑定到此账号") { model.bindDesktop(acc) }
                Button("为此账号新登录桌面端…") { model.loginDesktopFresh(acc) }
            }
        }
        Divider()
        Button("移除账号", role: .destructive) { model.remove(acc) }
    }
}

// MARK: 添加账号

struct UnsavedCard: View {
    @ObservedObject var model: AppModel
    let live: LiveIdentity
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 24)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.provider.title) 当前登录的账号").font(.system(size: 12.5, weight: .semibold))
                Text(live.email).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                Text("添加后可查看额度，并一键切换").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
            Button("添加") { model.beginSaveCurrent() }.buttonStyle(PillButton(fill: Theme.accent))
        }
        .padding(14)
        .background(Theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

struct AddBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button { model.beginLogin() } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("登录另一个账号")
            }
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text2)
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NameForm: View {
    @ObservedObject var model: AppModel
    @FocusState private var focus: Bool
    var isSave: Bool { model.route == .save }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 11) {
                    Avatar(key: model.currentLive?.uuid ?? model.draftName, label: model.draftName.isEmpty ? "?" : model.draftName, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isSave ? "添加当前登录账号" : "重命名账号").font(.system(size: 14, weight: .semibold))
                        if isSave { Text(model.currentLive?.email ?? "").font(.system(size: 11)).foregroundStyle(Theme.text2) }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("账号名称").font(.system(size: 11)).foregroundStyle(Theme.text2)
                    TextField("例如 work", text: $model.draftName)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(focus ? Theme.accent.opacity(0.85) : .white.opacity(0.1)))
                        .focused($focus)
                        .onSubmit { model.confirmForm() }
                    if let e = model.formError { Text(e).font(.system(size: 11)).foregroundStyle(Theme.bad) }
                }
                HStack {
                    Spacer()
                    Button("取消") { model.cancelRoute() }.buttonStyle(PillButton(fill: .white.opacity(0.1), textColor: Theme.text1))
                    Button(isSave ? "添加" : "保存") { model.confirmForm() }.buttonStyle(PillButton(fill: Theme.accent))
                }
            }
        }
        .onAppear { DispatchQueue.main.async { focus = true } }
    }
}

struct WaitingLogin: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Card {
            VStack(spacing: 14) {
                if let note = model.loginNote {
                    Image(systemName: model.loginSame ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle.fill")
                        .font(.system(size: 24)).foregroundStyle(Theme.warn)
                    Text(model.loginSame ? "没有登录新账号" : "登录没有完成").font(.system(size: 13, weight: .semibold))
                    Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                        .multilineTextAlignment(.center).lineLimit(8)
                    HStack(spacing: 8) {
                        Button("重试") { model.retryLogin() }.buttonStyle(PillButton(fill: Theme.accent))
                        Button("取消") { model.cancelRoute() }.buttonStyle(PillButton(fill: .white.opacity(0.1), textColor: Theme.text1))
                    }
                } else {
                    if model.loginURL == nil { ProgressView().controlSize(.regular) }
                    else { Image(systemName: "link.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent) }
                    Text(model.loginURL == nil ? "正在生成授权链接…" : "授权链接已就绪").font(.system(size: 13, weight: .semibold))
                    Text("用要添加的账号登录。完成后会自动添加到列表，不会改变你当前的 \(model.provider.title) 登录。")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        if model.loginURL != nil {
                            Button("在浏览器中打开") { model.openLoginURL() }.buttonStyle(PillButton(fill: Theme.accent))
                            Button("复制链接") { model.copyLoginURL() }
                                .buttonStyle(PillButton(fill: .white.opacity(0.14), textColor: Theme.text1))
                        }
                        Button("取消") { model.cancelRoute() }
                            .buttonStyle(PillButton(fill: .white.opacity(0.1), textColor: Theme.text1))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct EmptyState: View {
    let provider: Provider
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.slash").font(.system(size: 26)).foregroundStyle(Theme.text3)
            Text("还没有账号").font(.system(size: 13, weight: .semibold))
            Text(provider == .claude ? "先在 Claude Code 里登录，这里会自动识别并提示添加" : "先登录 Codex（ChatGPT 账号），这里会自动识别；也可以直接点下面的按钮登录").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 26)
    }
}

// MARK: 底栏

struct FooterBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 20)) { ctx in
                Text(model.lastUpdated.map { "更新于 " + Self.ago($0, ctx.date) } ?? "正在获取额度…")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    static func ago(_ d: Date, _ now: Date) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 15 { return "刚刚" }
        if s < 60 { return "\(s) 秒前" }
        return "\(s / 60) 分钟前"
    }
}


/// Codex 把登录存进了钥匙串（没有 auth.json）：读不到，也没法切换
struct KeyringNotice: View {
    var body: some View {
        Label("Codex 的登录存在钥匙串里，暂时读不到。在 ~/.codex/config.toml 里设置 cli_auth_credentials_store = \"file\" 并重新登录后即可识别。",
              systemImage: "info.circle")
            .font(.system(size: 11)).foregroundStyle(Theme.text2).padding(12)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

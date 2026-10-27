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
            case .addAPI, .editAPI:
                APIForm(model: model)
            }

            if model.route == .list { FooterBar(model: model) }
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
                Text(busy ? L("更新中", "Updating") : L("更新", "Update")).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).frame(height: 26)
            .background(LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .leading, endPoint: .trailing), in: Capsule())
            .shadow(color: Theme.accent.opacity(0.4), radius: 6, y: 1)
        }
        .buttonStyle(.plain).disabled(busy)
        .help(L("发现新版本 v\(version)，点击更新并重启", "New version v\(version) available. Click to update and restart"))
    }
}

struct HeaderBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(Provider.allCases) { p in
                    Button { model.provider = p } label: {
                        Label(L("\(p.title) · \(model.count(p)) 个账号", "\(p.title) · \(model.count(p)) account\(model.count(p) == 1 ? "" : "s")"), systemImage: model.provider == p ? "checkmark" : p.symbol)
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
                        Text(model.shown.isEmpty ? L("尚未添加账号", "No accounts yet") : L("\(model.shown.count) 个账号", "\(model.shown.count) account\(model.shown.count == 1 ? "" : "s")"))
                            .font(.system(size: 11)).foregroundStyle(Theme.text2)
                    }
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer()
            if let u = model.update { UpdateButton(version: u.version, busy: model.updating) { model.installUpdate() } }
            IconButton(symbol: "arrow.clockwise", spinning: model.manualRefreshing) { model.refreshManually() }
            Menu {
                Toggle(L("开机启动", "Launch at login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if ClaudeDesktop.installed, model.provider == .claude {
                    Toggle(L("同步 Claude 桌面端", "Sync Claude Desktop"), isOn: $model.syncDesktop)
                }
                Picker(L("刷新频率", "Refresh interval"), selection: $model.refreshInterval) {
                    Text(L("1 分钟", "1 min")).tag(60)
                    Text(L("2 分钟", "2 min")).tag(120)
                    Text(L("5 分钟", "5 min")).tag(300)
                    Text(L("10 分钟", "10 min")).tag(600)
                    Text(L("30 分钟", "30 min")).tag(1800)
                    Text(L("仅手动", "Manual only")).tag(0)
                }
                Picker("Language / 语言", selection: $model.language) {
                    Text("Auto / 跟随系统").tag("auto")
                    Text("English").tag("en")
                    Text("简体中文").tag("zh")
                }
                Divider()
                if let u = model.update {
                    Button(L("更新到 v\(u.version)", "Update to v\(u.version)")) { model.installUpdate() }.disabled(model.updating)
                } else {
                    Button(L("检查更新（当前 v\(Updater.currentVersion)）", "Check for updates (current v\(Updater.currentVersion))")) { model.checkUpdateManually() }
                }
                Button(L("退出 SwitchBoard", "Quit SwitchBoard")) { NSApp.terminate(nil) }
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
                        if acc.provider == .claude, acc.api == nil { DesktopChip(mark: model.desktopMark(acc)) }
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
                Text(L("使用中", "In use")).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.good.opacity(0.14), in: Capsule())
            .foregroundStyle(Theme.good)
        } else if confirmDelete {
            Button(L("确认移除", "Confirm remove")) { model.remove(acc) }.buttonStyle(PillButton(fill: Theme.bad))
        } else if hover || busy {
            HStack(spacing: 6) {
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(PillButton(fill: .white.opacity(0.08), textColor: Theme.text2, compact: true))
                if status == .needsLogin {
                    Button(L("重新登录", "Log in again")) { model.beginLogin(expect: acc) }.buttonStyle(PillButton(fill: Theme.accent))
                } else {
                    Button {
                        model.switchTo(acc)
                    } label: {
                        if busy { ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 24) } else { Text(L("切换", "Switch")) }
                    }
                    .buttonStyle(PillButton(fill: Theme.accent))
                }
            }
            .transition(.opacity)
        } else if isBest {
            Text(L("最空闲", "Least busy")).font(.system(size: 10.5, weight: .bold))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Theme.good.opacity(0.16), in: Capsule()).foregroundStyle(Theme.good)
        }
    }

    @ViewBuilder var body_: some View {
        if let api = acc.api {
            apiBody(api)
        } else if let u = usage {
            VStack(spacing: 8) {
                if let m = u.session { MeterLine(title: L("5 小时", "5-hour"), meter: m) }
                if let m = u.weekly { MeterLine(title: L("每周", "Weekly"), meter: m) }
                if let m = u.opus { MeterLine(title: "Opus", meter: m) }
                if let m = u.sonnet { MeterLine(title: "Sonnet", meter: m) }
                if u.session == nil && u.weekly == nil {
                    Text(L("暂无额度数据", "No quota data")).font(.system(size: 11)).foregroundStyle(Theme.text2)
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

extension AccountCard {
    /// 自定义 API：没有额度数据，只展示连通状态 + 模型映射
    @ViewBuilder func apiBody(_ api: APIConfig) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            switch status {
            case .error(let m):
                Label(m, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.warn)
            default:
                if model.apiOK.contains(acc.id) {
                    Label(L("已连接", "Connected"), systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.good)
                } else {
                    Label(L("检测中…", "Checking…"), systemImage: "network").font(.system(size: 11)).foregroundStyle(Theme.text2)
                }
            }
            if api.hasMapping {
                let parts = [(L("默认", "Default"), api.model), ("Opus", api.opus), ("Sonnet", api.sonnet), ("Haiku", api.haiku), (L("子代理", "Subagent"), api.subagent)].filter { !$0.1.isEmpty }
                Text(parts.map { "\($0.0) → \($0.1)" }.joined(separator: "  ·  "))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(L("登录已失效", "Login expired")).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            Spacer()
            Button(L("重新登录", "Log in again")) { model.beginLogin(expect: acc) }
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
        Button(L("重命名…", "Rename…")) { model.beginRename(acc) }
        if acc.api != nil {
            Button(L("编辑 API 配置…", "Edit API settings…")) { model.beginEditAPI(acc) }
            Button(L("重新检测连接", "Re-check connection")) { model.refreshManually() }
        } else {
            Button(L("刷新额度", "Refresh quota")) { model.refreshManually() }
        }
        if acc.provider == .claude, acc.api == nil, ClaudeDesktop.installed {
            Divider()
            switch model.desktopMark(acc) {
            case .active:
                Button(L("解除桌面端绑定", "Unbind Claude Desktop")) { model.unbindDesktop(acc) }
            case .saved:
                Button(L("切换桌面端到此账号", "Switch Claude Desktop to this account")) { Task { await model.switchDesktop(acc) } }
                Button(L("解除桌面端绑定", "Unbind Claude Desktop")) { model.unbindDesktop(acc) }
            case .none:
                Button(L("把当前桌面端登录绑定到此账号", "Bind current Claude Desktop login to this account")) { model.bindDesktop(acc) }
                Button(L("为此账号新登录桌面端…", "Log in to Claude Desktop as this account…")) { model.loginDesktopFresh(acc) }
            }
        }
        Divider()
        Button(L("移除账号", "Remove account"), role: .destructive) { model.remove(acc) }
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
                Text(L("\(model.provider.title) 当前登录的账号", "Account currently logged in to \(model.provider.title)")).font(.system(size: 12.5, weight: .semibold))
                Text(live.email).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                Text(L("添加后可查看额度，并一键切换", "Add it to see quota and switch in one click")).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
            Button(L("添加", "Add")) { model.beginSaveCurrent() }.buttonStyle(PillButton(fill: Theme.accent))
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
        if model.provider == .claude {
            // 两个按钮并排，文案缩短
            HStack(spacing: 8) {
                button("plus", L("登录另一个账号", "Add account")) { model.beginLogin() }
                button("server.rack", L("自定义 API", "Custom API")) { model.beginAddAPI() }
                    .help(L("添加自定义 API / 中转站", "Add custom API / relay"))
            }
        } else {
            button("plus", L("登录另一个账号", "Log in to another account")) { model.beginLogin() }
        }
    }

    private func button(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
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

// MARK: 自定义 API 表单（分组列表：标签在左、值在右，一行一个字段）

struct FormGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
    }
}

struct FormDivider: View {
    var body: some View { Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 12) }
}

struct FormRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                .frame(width: 72, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).frame(height: 38)
    }
}

/// 一行一个模型：拿到模型列表后用下拉选择，否则手动输入
struct ModelRow: View {
    let title: String
    let options: [String]
    @Binding var value: String
    var body: some View {
        FormRow(title: title) {
            if options.isEmpty {
                TextField(L("可留空", "Optional"), text: $value).textFieldStyle(.plain).font(.system(size: 12.5))
            } else {
                Menu {
                    Button(L("不设置", "Not set")) { value = "" }
                    Divider()
                    // 当前值不在列表里（例如换了站点）也保留可见
                    ForEach(options.contains(value) || value.isEmpty ? options : [value] + options, id: \.self) { m in
                        Button { value = m } label: { if m == value { Label(m, systemImage: "checkmark") } else { Text(m) } }
                    }
                } label: {
                    HStack {
                        Text(value.isEmpty ? L("不设置", "Not set") : value).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(value.isEmpty ? Theme.text3 : Theme.text1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text2)
                    }
                    .font(.system(size: 12.5)).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            }
        }
    }
}

struct APIForm: View {
    @ObservedObject var model: AppModel
    var editing: Bool { if case .editAPI = model.route { return true }; return false }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(editing ? L("编辑 API 账号", "Edit API account") : L("添加自定义 API / 中转站", "Add custom API / relay"))
                    .font(.system(size: 14, weight: .semibold))

                section(L("连接", "Connection")) {
                    FormGroup {
                        FormRow(title: L("名称", "Name")) {
                            TextField(L("例如 relay-a", "e.g. relay-a"), text: $model.draftName).textFieldStyle(.plain).font(.system(size: 12.5))
                        }
                        FormDivider()
                        FormRow(title: "Base URL") {
                            TextField("https://api.example.com", text: $model.draftBaseURL).textFieldStyle(.plain).font(.system(size: 12.5))
                        }
                        FormDivider()
                        FormRow(title: L("密钥", "API key")) {
                            HStack(spacing: 6) {
                                SecureField(editing ? L("留空 = 不修改", "Leave empty to keep") : "sk-…", text: $model.draftKey)
                                    .textFieldStyle(.plain).font(.system(size: 12.5))
                                Button { model.fetchModels() } label: {
                                    if model.modelsLoading { ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 56) }
                                    else { Text(L("获取模型", "Fetch models")) }
                                }
                                .buttonStyle(PillButton(fill: .white.opacity(0.12), textColor: Theme.text1, compact: true))
                                .help(L("用当前 Base URL 和密钥获取模型列表", "Fetch the model list with the current Base URL and key"))
                            }
                        }
                    }
                    if let e = model.modelsError { Text(e).font(.system(size: 10.5)).foregroundStyle(Theme.warn) }
                    else if !model.apiModels.isEmpty {
                        Text(L("已获取 \(model.apiModels.count) 个模型，可在下方选择", "\(model.apiModels.count) models loaded. Pick them below")).font(.system(size: 10.5)).foregroundStyle(Theme.good)
                    }
                }

                section(L("模型（可选）", "Models (optional)")) {
                    FormGroup {
                        ModelRow(title: L("默认模型", "Default"), options: model.apiModels, value: $model.draftModel)
                        FormDivider()
                        ModelRow(title: "Opus", options: model.apiModels, value: $model.draftOpus)
                        FormDivider()
                        ModelRow(title: "Sonnet", options: model.apiModels, value: $model.draftSonnet)
                        FormDivider()
                        ModelRow(title: "Haiku", options: model.apiModels, value: $model.draftHaiku)
                        FormDivider()
                        ModelRow(title: L("子代理", "Subagent"), options: model.apiModels, value: $model.draftSubagent)
                    }
                }

                if let e = model.formError { Text(e).font(.system(size: 11)).foregroundStyle(Theme.bad) }
                HStack {
                    Spacer()
                    Button(L("取消", "Cancel")) { model.cancelRoute() }.buttonStyle(PillButton(fill: .white.opacity(0.1), textColor: Theme.text1))
                    Button(editing ? L("保存", "Save") : L("添加", "Add")) { model.confirmForm() }.buttonStyle(PillButton(fill: Theme.accent))
                }
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text2).padding(.leading, 4)
            content()
        }
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
                        Text(isSave ? L("添加当前登录账号", "Add current account") : L("重命名账号", "Rename account")).font(.system(size: 14, weight: .semibold))
                        if isSave { Text(model.currentLive?.email ?? "").font(.system(size: 11)).foregroundStyle(Theme.text2) }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("账号名称", "Account name")).font(.system(size: 11)).foregroundStyle(Theme.text2)
                    TextField(L("例如 work", "e.g. work"), text: $model.draftName)
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
                    Button(L("取消", "Cancel")) { model.cancelRoute() }.buttonStyle(PillButton(fill: .white.opacity(0.1), textColor: Theme.text1))
                    Button(isSave ? L("添加", "Add") : L("保存", "Save")) { model.confirmForm() }.buttonStyle(PillButton(fill: Theme.accent))
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
                    Text(model.loginSame ? L("没有登录新账号", "No new account logged in") : L("登录没有完成", "Login did not finish")).font(.system(size: 13, weight: .semibold))
                    Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                        .multilineTextAlignment(.center).lineLimit(8)
                    HStack(spacing: 8) {
                        Button(L("重试", "Retry")) { model.retryLogin() }.buttonStyle(PillButton(fill: Theme.accent))
                        Button(L("取消", "Cancel")) { model.cancelRoute() }.buttonStyle(PillButton(fill: .white.opacity(0.1), textColor: Theme.text1))
                    }
                } else {
                    if model.loginURL == nil { ProgressView().controlSize(.regular) }
                    else { Image(systemName: "link.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent) }
                    Text(model.loginURL == nil ? L("正在生成授权链接…", "Generating authorization link…") : L("授权链接已就绪", "Authorization link ready")).font(.system(size: 13, weight: .semibold))
                    Text(L("用要添加的账号登录。完成后会自动添加到列表，不会改变你当前的 \(model.provider.title) 登录。", "Log in with the account you want to add. It is added to the list automatically and your current \(model.provider.title) login is not changed."))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        if model.loginURL != nil {
                            Button(L("在浏览器中打开", "Open in browser")) { model.openLoginURL() }.buttonStyle(PillButton(fill: Theme.accent))
                            Button(L("复制链接", "Copy link")) { model.copyLoginURL() }
                                .buttonStyle(PillButton(fill: .white.opacity(0.14), textColor: Theme.text1))
                        }
                        Button(L("取消", "Cancel")) { model.cancelRoute() }
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
            Text(L("还没有账号", "No accounts yet")).font(.system(size: 13, weight: .semibold))
            Text(provider == .claude ? L("先在 Claude Code 里登录，这里会自动识别并提示添加", "Log in with Claude Code first; it will be detected here and offered for adding") : L("先登录 Codex（ChatGPT 账号），这里会自动识别；也可以直接点下面的按钮登录", "Log in to Codex (ChatGPT account) first and it will be detected here, or use the button below to log in")).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 26)
    }
}

// MARK: 底栏

struct FooterBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(model.lastUpdated.map { L("更新于 ", "Updated ") + Self.ago($0, ctx.date) } ?? L("正在获取额度…", "Fetching quota…"))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    static func ago(_ d: Date, _ now: Date) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 1 { return L("刚刚", "just now") }
        if s < 60 { return L("\(s) 秒前", "\(s)s ago") }
        return L("\(s / 60) 分钟前", "\(s / 60)m ago")
    }
}


/// Codex 把登录存进了钥匙串（没有 auth.json）：读不到，也没法切换
struct KeyringNotice: View {
    var body: some View {
        Label(L("Codex 的登录存在钥匙串里，暂时读不到。在 ~/.codex/config.toml 里设置 cli_auth_credentials_store = \"file\" 并重新登录后即可识别。", "Codex stores its login in the Keychain, so it cannot be read yet. Set cli_auth_credentials_store = \"file\" in ~/.codex/config.toml and log in again to have it detected."),
              systemImage: "info.circle")
            .font(.system(size: 11)).foregroundStyle(Theme.text2).padding(12)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

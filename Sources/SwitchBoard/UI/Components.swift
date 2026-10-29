import SwiftUI

struct Avatar: View {
    let key: String
    let label: String
    let size: CGFloat
    var glow = false
    var body: some View {
        let (a, b) = Theme.avatar(key)
        ZStack {
            Circle().fill(LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(String(label.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.8))
        .shadow(color: b.opacity(glow ? 0.6 : 0.25), radius: glow ? 10 : 4, y: 2)
    }
}

struct PlanPill: View {
    let text: String
    var tint: Color {
        let t = text.lowercased()
        if t.hasPrefix("max") { return Theme.accent }
        if t.hasPrefix("pro") { return Color(red: 0.40, green: 0.62, blue: 1.00) }
        if t.hasPrefix("team") || t.hasPrefix("enterprise") || t.hasPrefix("business") || t.hasPrefix("edu") { return Theme.good }
        if t.hasPrefix("plus") { return Color(red: 0.25, green: 0.82, blue: 0.80) }
        return .gray
    }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold)).textCase(.uppercase)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(tint.opacity(0.24), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 0.7))
            .foregroundStyle(tint)
            .lineLimit(1).fixedSize()
    }
}

struct PillButton: ButtonStyle {
    var fill: Color
    var textColor: Color = .white
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(textColor)
            .padding(.horizontal, compact ? 9 : 14).padding(.vertical, 6)
            .background(fill.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButton: View {
    let symbol: String
    var spinning = false
    let action: () -> Void
    @State private var hover = false
    @State private var startedAt: Date?
    @State private var endedAt: Date?
    private let speed = 360.0 / 0.9   // 度/秒

    /// 转动中匀速旋转；停止后继续转完当前这一圈再静止，不会反向回转
    private func degrees(at now: Date) -> Double {
        guard let startedAt else { return 0 }
        let deg = now.timeIntervalSince(startedAt) * speed
        guard let endedAt else { return deg }
        let target = (endedAt.timeIntervalSince(startedAt) * speed / 360).rounded(.up) * 360
        return min(deg, target)
    }

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: startedAt == nil)) { ctx in
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Theme.text1 : Theme.text2)
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(degrees(at: ctx.date)))
            }
            .frame(width: 28, height: 28)
            .background(.white.opacity(hover ? 0.13 : 0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .onAppear { if spinning { startedAt = Date() } }
        .onChange(of: spinning) { _, on in
            if on {
                startedAt = Date(); endedAt = nil
            } else if let s = startedAt {
                let now = Date()
                endedAt = now
                let total = now.timeIntervalSince(s) * speed
                let remain = ((total / 360).rounded(.up) * 360 - total) / speed
                Task {
                    try? await Task.sleep(nanoseconds: UInt64((remain + 0.05) * 1_000_000_000))
                    if endedAt == now { startedAt = nil; endedAt = nil }
                }
            }
        }
    }
}

/// 一行额度：标题 | 进度条 | 剩余% | 倒计时 · 重置时刻
struct MeterLine: View {
    let title: String
    let meter: Meter
    /// 默认显示倒计时，为 true 时（卡片悬浮）改显示重置时刻
    var reveal = false
    @State private var shown = 0.0

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2)
                .frame(width: 44, alignment: .leading)
            Bar(value: shown, tint: Theme.tint(meter.remaining), height: 5)
            Text("\(Int(meter.remaining.rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.tint(meter.remaining))
                .contentTransition(.numericText())
                .frame(width: 38, alignment: .trailing)
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(resetText(now: ctx.date))
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.text2)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: reveal)
            }
            .frame(width: 58, alignment: .trailing)
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { shown = meter.remaining } }
        .onChange(of: meter.remaining) { _, v in withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { shown = v } }
    }
}

extension MeterLine {
    func resetText(now: Date) -> String {
        guard let (left, at) = resetParts(meter.resetsAt, now: now) else { return "—" }
        return reveal ? at : left
    }
}

struct Bar: View {
    let value: Double
    let tint: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * value / 100))
                    .shadow(color: tint.opacity(0.6), radius: 4)
            }
        }
        .frame(height: height)
    }
}

struct Card<Content: View>: View {
    var highlight = false
    var radius: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.white.opacity(highlight ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(highlight ? Theme.accent.opacity(0.6) : .white.opacity(0.08), lineWidth: highlight ? 1.2 : 0.8))
            .shadow(color: highlight ? Theme.accent.opacity(0.2) : .clear, radius: 16)
    }
}

/// 账号对应的 Claude 桌面端状态：使用中（实心）/ 已保存快照（描边）/ 无（不显示）
struct DesktopChip: View {
    let mark: DesktopMark
    var body: some View {
        switch mark {
        case .none: EmptyView()
        case .active:
            Image(systemName: "macwindow").font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Theme.good).frame(width: 20, height: 18)
                .background(Theme.good.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help(L("Claude 桌面端：正在使用此账号", "Claude Desktop: using this account"))
        case .saved:
            Image(systemName: "macwindow").font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.text2).frame(width: 20, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.28), lineWidth: 0.8))
                .help(L("Claude 桌面端：已保存此账号的登录，切换时会同步", "Claude Desktop: login saved for this account; it syncs when you switch"))
        }
    }
}

/// 邮箱默认把用户名中间模糊掉，鼠标悬浮时显示完整
struct MaskedEmail: View {
    let email: String
    /// 外部（如整张卡片）控制是否显示完整；为 nil 时由邮箱自身的悬浮决定
    var reveal: Bool? = nil
    @State private var hover = false

    /// (文本, 是否模糊) 片段：保留用户名前 2 位和域名后缀，中间（含 @）整体模糊
    private var segments: [(String, Bool)]? {
        guard let at = email.firstIndex(of: "@"), email.distance(from: email.startIndex, to: at) > 3 else { return nil }
        let head = String(email.prefix(2))
        if let dot = email.lastIndex(of: "."), dot > at {
            return [(head, false), (String(email[email.index(email.startIndex, offsetBy: 2)..<dot]), true), (String(email[dot...]), false)]
        }
        return [(head, false), (String(email.dropFirst(2)), true)]
    }

    var body: some View {
        Group {
            if let segs = segments {
                HStack(spacing: 0) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                        Text(seg.0).blur(radius: seg.1 && !(reveal ?? hover) ? 4 : 0)
                    }
                }
            } else {
                Text(email)
            }
        }
        .lineLimit(1).truncationMode(.middle)
        .animation(.easeOut(duration: 0.15), value: reveal ?? hover)
        .onHover { hover = $0 }
    }
}

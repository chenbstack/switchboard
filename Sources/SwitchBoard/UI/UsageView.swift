import SwiftUI

func compactTokens(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
    if d >= 1e6 { return String(format: d >= 1e8 ? "%.0fM" : "%.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: d >= 1e5 ? "%.0fK" : "%.1fK", d / 1e3) }
    return "\(n)"
}

/// 本机 token 用量页：跟随当前 provider，今天 / 近 7 天
struct UsagePage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let s = model.tokenStats.summary(provider: model.provider, days: model.usageDays)
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button { model.cancelRoute() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.text1).frame(width: 26, height: 26)
                        .background(.white.opacity(0.1), in: Circle())
                }.buttonStyle(.plain)
                Text(L("\(model.provider.title) 用量", "\(model.provider.title) usage")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text1)
                if model.tokenScanning { ProgressView().controlSize(.small).scaleEffect(0.6) }
                Spacer()
                HStack(spacing: 2) {
                    ForEach([(1, L("今天", "Today")), (7, L("7 天", "7 days"))], id: \.0) { d, t in
                        Button { model.usageDays = d } label: {
                            Text(t).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(model.usageDays == d ? .white : Theme.text2)
                                .padding(.horizontal, 10).frame(height: 24)
                                .background(model.usageDays == d ? Theme.accent.opacity(0.9) : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(2).background(.white.opacity(0.08), in: Capsule())
            }

            if !s.hasData {
                Text(model.tokenScanning ? L("正在统计本机日志…", "Scanning local logs…") : L("这段时间没有记录", "Nothing recorded in this period"))
                    .font(.system(size: 12)).foregroundStyle(Theme.text3).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                Card {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("总 token", "Total tokens")).font(.system(size: 11)).foregroundStyle(Theme.text3)
                            Text(compactTokens(s.total.total)).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(Theme.text1)
                            if s.total.cost > 0 {
                                Text("≈ $" + String(format: "%.2f", s.total.cost)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                            }
                            Text(L("\(s.total.messages) 次请求", "\(s.total.messages) requests")).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                        HitRing(rate: s.total.hitRate)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    StatTile(L("输入", "Input"), s.total.input)
                    StatTile(L("输出", "Output"), s.total.output)
                    StatTile(L("缓存读", "Cache rd"), s.total.cacheRead)
                    StatTile(L("缓存写", "Cache wr"), s.total.cacheWrite)
                    StatTile(L("推理", "Reason"), s.total.reasoning)
                }
                Card(radius: 16) {
                    VStack(spacing: 10) {
                        ForEach(s.byModel, id: \.model) { m in UsageModelRow(name: m.model, b: m.b) }
                    }
                }
            }
        }
    }
}

/// 用量页的固定底栏：统计口径说明
struct UsageFooter: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if model.usageDays > 1, model.tokenStats.since > Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970 {
                Text(L("统计从 ", "Counting since ") + Date(timeIntervalSince1970: model.tokenStats.since).formatted(.dateTime.month().day().hour().minute()) + L(" 开始，之后持续累积", ", accumulating from there"))
            }
            Text(L("统计自本机 ~/.claude 与 ~/.codex 的会话日志，网页端 / 桌面端对话不在其中。tok/s 只统计流式生成阶段（不含首 token 延迟），仅 Claude 有。", "Counted from local ~/.claude and ~/.codex session logs; web / desktop chats are not included. tok/s covers streaming generation only (no first-token latency), Claude only."))
        }
        .font(.system(size: 10)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatTile: View {
    let title: String, value: Int
    init(_ t: String, _ v: Int) { title = t; value = v }
    var body: some View {
        VStack(spacing: 3) {
            Text(compactTokens(value)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text1)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.system(size: 9.5)).foregroundStyle(Theme.text3).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct HitRing: View {
    let rate: Double?
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: 6)
            Circle().trim(from: 0, to: rate ?? 0)
                .stroke(LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(rate.map { String(format: "%.1f%%", $0 * 100) } ?? "—").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.text1)
                Text(L("缓存命中", "cache hit")).font(.system(size: 8.5)).foregroundStyle(Theme.text3)
            }
        }
        .frame(width: 74, height: 74)
    }
}

private struct UsageModelRow: View {
    let name: String
    let b: TokenBucket
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text1).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(compactTokens(b.total)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text1)
            }
            HStack(spacing: 10) {
                if let h = b.hitRate { Text(String(format: L("命中 %.1f%%", "hit %.1f%%"), h * 100)) }
                if let v = b.tokPerSec { Text("\(Int(v)) tok/s") }
                Spacer()
                if b.cost > 0 { Text("$" + String(format: "%.2f", b.cost)).foregroundStyle(Theme.accent) }
            }
            .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
        }
    }
}

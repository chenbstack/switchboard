import AppKit
import SwiftUI

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 近乎不透明的暖炭色底 + 顶部主题色光晕：不再被后面的白色页面透灰
struct PanelBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.125, green: 0.105, blue: 0.098),
                                    Color(red: 0.075, green: 0.066, blue: 0.066)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.accent.opacity(0.20), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 320)
        }
        .opacity(0.97)
    }
}

struct PanelRoot: View {
    @ObservedObject var model: AppModel
    var onHeight: (CGFloat) -> Void
    var body: some View {
        ScrollView(showsIndicators: false) {
            RootView(model: model)
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        }
        .frame(width: Theme.panelWidth)
        .background(PanelBackground())
        .onPreferenceChange(HeightKey.self) { onHeight($0) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var item: NSStatusItem!
    var panel: HUDPanel!
    var outsideMonitor: Any?
    var contentHeight: CGFloat = 320

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        // behindWindow 的模糊由窗口服务器绘制，layer.cornerRadius 裁不掉，白底时四角会露出直角；
        // 必须用 maskImage 让系统按圆角形状绘制模糊与阴影
        effect.maskImage = Self.roundedMask(radius: 24)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 24
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        let host = NSHostingView(rootView: PanelRoot(model: model) { [weak self] h in
            DispatchQueue.main.async { self?.setHeight(h) }
        })
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 320),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false   // 切到浏览器等其他 App 时不自动隐藏

        model.onChange = { [weak self] in self?.updateStatusItem() }
        model.start()
        updateStatusItem()

        // 调试：--snapshot <path> 离屏渲染面板为 PNG
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let view = RootView(model: self.model).frame(width: Theme.panelWidth)
                    .background(Color(red: 0.13, green: 0.12, blue: 0.13)).environment(\.colorScheme, .dark)
                let r = ImageRenderer(content: view)
                r.scale = 2
                if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
                   let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
                NSApp.terminate(nil)
            }
        }
        // 调试：--show 启动即展开面板
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.show() }
        }
    }

    // MARK: 菜单栏：环形仪表 + 当前账号 5 小时剩余

    func updateStatusItem() {
        guard let button = item.button else { return }
        let remaining = model.activeAccount.flatMap { model.usage[$0.id]?.session?.remaining }
        button.image = Self.ring(fraction: (remaining ?? 100) / 100, dim: remaining == nil)
        button.attributedTitle = NSAttributedString(
            string: remaining.map { " \(Int($0.rounded()))%" } ?? "",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    static func ring(fraction: Double, dim: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY), r: CGFloat = 6.5
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.2
            NSColor.black.withAlphaComponent(0.28).setStroke()
            track.stroke()
            if !dim {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: r, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(max(0.02, min(1, fraction))), clockwise: true)
                arc.lineWidth = 2.2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: 面板

    @objc func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        guard let button = item.button, let bw = button.window else { return }
        model.refreshIfStale()
        place(anchor: bw.convertToScreen(button.convert(button.bounds, to: nil)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // 添加/登录流程中保持可见，只能通过菜单栏图标或「取消」关闭
            Task { @MainActor in
                guard let self, self.model.route == .list else { return }
                self.hide()
            }
        }
    }

    func hide() {
        panel.orderOut(nil)
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
    }

    func place(anchor: NSRect) {
        let h = min(contentHeight, 660)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        var x = anchor.midX - Theme.panelWidth / 2
        if let vf = screen?.visibleFrame { x = min(max(x, vf.minX + 8), vf.maxX - Theme.panelWidth - 8) }
        panel.setFrame(NSRect(x: x, y: anchor.minY - 8 - h, width: Theme.panelWidth, height: h), display: true)
    }

    func setHeight(_ h: CGFloat) {
        guard h > 0 else { return }
        contentHeight = h
        guard panel.isVisible else { return }
        let newH = min(h, 660)
        var f = panel.frame
        f.origin.y += f.height - newH
        f.size.height = newH
        panel.setFrame(f, display: true, animate: true)
    }
}

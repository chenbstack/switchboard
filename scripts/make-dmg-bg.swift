// 生成 dmg 窗口背景（660x400）：swift scripts/make-dmg-bg.swift <输出目录>
import AppKit

let W = 660, H = 400
func render(scale: Int) -> Data {
    let px = (W * scale, H * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px.0, pixelsHigh: px.1, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)   // 保证 @2x 以 144dpi 标记
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    let full = NSRect(x: 0, y: 0, width: W, height: H)

    NSGradient(colors: [NSColor(red: 1.00, green: 0.975, blue: 0.95, alpha: 1), NSColor(red: 0.975, green: 0.925, blue: 0.885, alpha: 1)])!
        .draw(in: full, angle: -90)
    NSGradient(colors: [NSColor(red: 0.98, green: 0.45, blue: 0.27, alpha: 0.22), .clear],
               atLocations: [0, 1], colorSpace: .deviceRGB)!
        .draw(fromCenter: NSPoint(x: 80, y: 400), radius: 0, toCenter: NSPoint(x: 80, y: 400), radius: 420, options: [])
    NSGradient(colors: [NSColor(red: 0.80, green: 0.30, blue: 0.28, alpha: 0.14), .clear],
               atLocations: [0, 1], colorSpace: .deviceRGB)!
        .draw(fromCenter: NSPoint(x: 620, y: 0), radius: 0, toCenter: NSPoint(x: 620, y: 0), radius: 360, options: [])

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        (s as NSString).draw(in: NSRect(x: 0, y: y, width: CGFloat(W), height: size * 1.4), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(red: 0.20, green: 0.12, blue: 0.10, alpha: alpha), .paragraphStyle: p])
    }
    text("SwitchBoard", size: 26, weight: .bold, alpha: 0.95, y: 326)
    text("Claude / Codex 账号一键切换", size: 13, weight: .regular, alpha: 0.55, y: 298)
    text("将 SwitchBoard 拖入 Applications 完成安装", size: 12.5, weight: .medium, alpha: 0.6, y: 36)

    // Finder 对自定义背景的图标文字始终用深色，所以背景必须是浅色
    // 图标中心 (180,190) → (480,190)（dmgbuild 坐标自上而下，这里自下而上：y = 400-190 = 210）
    let cy: CGFloat = 210
    let arrow = NSBezierPath()
    arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 268, y: cy)); arrow.line(to: NSPoint(x: 392, y: cy))
    arrow.move(to: NSPoint(x: 378, y: cy + 14)); arrow.line(to: NSPoint(x: 394, y: cy)); arrow.line(to: NSPoint(x: 378, y: cy - 14))
    NSColor(red: 0.92, green: 0.42, blue: 0.28, alpha: 0.85).setStroke()
    let dash: [CGFloat] = [0.1, 9]
    let shaft = NSBezierPath(); shaft.lineWidth = 3; shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: 268, y: cy)); shaft.line(to: NSPoint(x: 380, y: cy))
    shaft.setLineDash(dash, count: 2, phase: 0); shaft.stroke()
    let head = NSBezierPath(); head.lineWidth = 3; head.lineCapStyle = .round; head.lineJoinStyle = .round
    head.move(to: NSPoint(x: 380, y: cy + 14)); head.line(to: NSPoint(x: 396, y: cy)); head.line(to: NSPoint(x: 380, y: cy - 14)); head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
try! render(scale: 1).write(to: URL(fileURLWithPath: "\(out)/dmg-bg.png"))
// 不要输出 dmg-bg@2x.png：dmgbuild 看到同名 @2x 会自动合成多分辨率 TIFF，部分系统的访达会把它放大 2 倍显示

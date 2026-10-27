import Foundation
import AppKit

struct UpdateInfo: Equatable {
    let version: String
    let url: URL
}

/// 通过 GitHub Releases 检查并安装更新：下载 zip → 解压 → 退出后由脚本替换 .app 并重新打开
enum Updater {
    static let repo = "chenbstack/switchboard"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func check() async -> UpdateInfo? {
        guard let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: api, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard newer(version, than: currentVersion),
              let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let s = zip["browser_download_url"] as? String, let url = URL(string: s) else { return nil }
        return UpdateInfo(version: version, url: url)
    }

    /// 下载并准备好替换；成功后调用方应立即退出 App（脚本会等它退出后完成替换并重新打开）
    static func install(_ info: UpdateInfo) async throws {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { throw AppError(L("当前不是从 .app 运行，无法自动更新", "Not running from an .app bundle; cannot auto-update")) }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw AppError(L("没有权限写入 \(app.deletingLastPathComponent().path)，请手动更新", "No permission to write to \(app.deletingLastPathComponent().path). Please update manually"))
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("SwitchBoard-update-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (tmp, resp) = try await URLSession.shared.download(from: info.url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw AppError(L("下载失败", "Download failed")) }
        let zip = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)

        let out = work.appendingPathComponent("out")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        let new = out.appendingPathComponent(app.lastPathComponent)
        guard FileManager.default.fileExists(atPath: new.appendingPathComponent("Contents/MacOS").path) else {
            throw AppError(L("更新包内容不正确", "The update package is invalid"))
        }

        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(app.path)" && mv "\(new.path)" "\(app.path)" && xattr -dr com.apple.quarantine "\(app.path)"
        open "\(app.path)"
        rm -rf "\(work.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    private static func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw AppError(L("解压更新包失败", "Failed to unpack the update")) }
    }
}

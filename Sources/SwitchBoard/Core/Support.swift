import Foundation
import CryptoKit

// MARK: - 子进程（异步 + 超时，永不阻塞主线程）

struct ShellResult {
    var code: Int32
    var out: String
    var err: String
    var timedOut = false
}

enum Shell {
    static func run(_ exe: String, _ args: [String], stdin: String? = nil, timeout: TimeInterval = 10) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let o = Pipe(), e = Pipe(), i = Pipe()
                p.standardOutput = o
                p.standardError = e
                p.standardInput = i
                do { try p.run() } catch {
                    cont.resume(returning: ShellResult(code: -1, out: "", err: "\(error)"))
                    return
                }
                var timedOut = false
                let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                if let stdin { i.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? i.fileHandleForWriting.close()
                var od = Data(), ed = Data()
                let g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { od = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.enter(); DispatchQueue.global().async { ed = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.wait()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: ShellResult(code: p.terminationStatus,
                                                   out: String(decoding: od, as: UTF8.self),
                                                   err: String(decoding: ed, as: UTF8.self),
                                                   timedOut: timedOut))
            }
        }
    }

    static func openInTerminal(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", #"tell application "Terminal" to activate"#,
                       "-e", "tell application \"Terminal\" to do script \"\(command)\""]
        try? p.run()
    }
}

// MARK: - 钥匙串（走 /usr/bin/security：ACL 稳定，不会因重新编译反复弹授权；写入经 stdin + 十六进制，密钥不出现在 argv）

enum Keychain {
    private static let sec = "/usr/bin/security"

    private static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func read(service: String, account: String? = nil) async -> String? {
        var a = ["find-generic-password", "-s", service]
        if let account { a += ["-a", account] }
        a.append("-w")
        let r = await Shell.run(sec, a, timeout: 6)
        return r.code == 0 ? r.out.trimmingCharacters(in: .newlines) : nil
    }

    @discardableResult
    static func write(service: String, account: String, value: String) async -> Bool {
        let hex = value.utf8.map { String(format: "%02x", $0) }.joined()
        let cmd = "add-generic-password -U -s \(q(service)) -a \(q(account)) -X \(hex)\n"
        let r = await Shell.run(sec, ["-i"], stdin: cmd, timeout: 8)
        return r.code == 0 && !r.err.contains("SecKeychain") && !r.err.lowercased().contains("error")
    }

    /// 只查条目是否存在（不带 -w，不读密码，不会触发授权弹窗）
    static func exists(service: String) async -> Bool {
        await Shell.run(sec, ["find-generic-password", "-s", service], timeout: 6).code == 0
    }

    static func delete(service: String, account: String) async {
        _ = await Shell.run(sec, ["delete-generic-password", "-s", service, "-a", account], timeout: 6)
    }

    /// 现有条目的 acct（Claude Code 写入时用的用户名）
    static func accountName(service: String) async -> String? {
        let r = await Shell.run(sec, ["find-generic-password", "-s", service], timeout: 6)
        let text = r.out + "\n" + r.err
        guard let re = try? NSRegularExpression(pattern: #""acct"<blob>="([^"]*)""#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let rg = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[rg])
    }
}

// MARK: - JSONValue（无损携带 oauthAccount 等任意结构）

enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(any: Any?) {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n.rounded() == n && abs(n) < 9e15 ? Int64(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.map { $0.any }
        case .object(let o): return o.mapValues { $0.any }
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

enum FileJSON {
    static func read(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func write(_ obj: [String: Any], to url: URL) throws {
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        try d.write(to: url, options: .atomic)
    }
}

// MARK: - 后台运行 `claude auth login`（无需终端窗口；claude 自己打开浏览器并监听回调）

enum ClaudeCLI {
    static func executable() async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let r = await Shell.run("/bin/zsh", ["-lc", "command -v claude"], timeout: 6)
        let path = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.code == 0 && !path.isEmpty ? path : nil
    }
}

/// 在「独立 CLAUDE_CONFIG_DIR + 伪终端」里运行 `claude auth login`
/// - 独立目录：登录结果写进它自己的钥匙串条目和 .claude.json，不影响当前登录（与参考项目一致）
/// - 伪终端（script）：claude 需要 TTY，无 TTY 时授权后换 token 会报 `Socket is closed`
/// - BROWSER 指向只记录链接的脚本：不自动打开浏览器，由界面提供「打开 / 复制链接」
final class LoginProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var buffer = ""
    private let stdinPipe = Pipe()      // 保持打开，否则 claude 会读到 EOF
    let dir: URL

    init() {
        let tmp = NSTemporaryDirectory().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        dir = URL(fileURLWithPath: "/" + tmp + "/SwitchBoard-login-\(UUID().uuidString.prefix(8))")
    }

    private var urlFile: URL { dir.appendingPathComponent("login-url.txt") }
    private var configDir: URL { dir.appendingPathComponent("cfg") }

    /// claude 为自定义配置目录使用的钥匙串 service：前缀 + 目录路径 SHA-256 前 8 位
    var keychainService: String {
        let h = SHA256.hash(data: Data(configDir.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + h.prefix(8)
    }

    func authorizeURL() -> String? {
        guard let s = try? String(contentsOf: urlFile, encoding: .utf8) else { return nil }
        let u = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.hasPrefix("http") ? u : nil
    }

    func oauthAccount() -> JSONValue? {
        guard let j = FileJSON.read(configDir.appendingPathComponent(".claude.json")), let a = j["oauthAccount"] else { return nil }
        return JSONValue(any: a)
    }

    func start(executable: String, email: String?, onExit: @escaping @Sendable (Int32, String) -> Void) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("capture-url.sh")
        try "#!/bin/sh\nprintf '%s' \"$1\" > '\(urlFile.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", executable, "auth", "login"] + (email.map { ["--email", $0] } ?? [])
        var env = ProcessInfo.processInfo.environment
        env["BROWSER"] = script.path
        env["CLAUDE_CONFIG_DIR"] = configDir.path
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = stdinPipe
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock(); self.buffer += String(decoding: data, as: UTF8.self); self.lock.unlock()
        }
        process.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            onExit(p.terminationStatus, self?.tail() ?? "")
        }
        try process.run()
    }

    private func tail() -> String {
        lock.lock(); defer { lock.unlock() }
        let clean = buffer.replacingOccurrences(of: #"\u001B[\[\]][0-9;?]*[A-Za-z]?"#, with: "", options: .regularExpression)
        return String(clean.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))
    }

    var succeeded: Bool { lock.lock(); defer { lock.unlock() }; return buffer.contains("Login successful") }

    func terminate() {
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    /// 删除临时钥匙串条目与目录
    func cleanup() async {
        terminate()
        _ = await Shell.run("/usr/bin/security", ["delete-generic-password", "-s", keychainService], timeout: 6)
        try? FileManager.default.removeItem(at: dir)
    }
}

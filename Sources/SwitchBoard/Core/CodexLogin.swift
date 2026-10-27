import Foundation
import Network
import CryptoKit

/// 应用内完成 Codex（ChatGPT）登录：标准 OAuth 授权码 + PKCE，回调落在本机 127.0.0.1:1455（与 codex 命令行相同的客户端和回调地址）。
/// 因此不依赖 codex 命令行，也不会自动打开浏览器——由界面上的按钮决定何时打开链接。
final class CodexLogin: @unchecked Sendable {
    static let port: UInt16 = 1455
    static let redirect = "http://127.0.0.1:1455/auth/callback"

    private let verifier: String
    private let state: String
    let authorizeURL: String
    private var listener: NWListener?
    private var cont: CheckedContinuation<String, Error>?
    private let lock = NSLock()
    private var finished = false

    init() {
        func rand(_ n: Int) -> String {
            var b = [UInt8](repeating: 0, count: n)
            _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
            return Data(b).base64URL
        }
        verifier = rand(64)
        state = rand(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: CodexService.clientID),
            .init(name: "redirect_uri", value: Self.redirect),
            .init(name: "scope", value: "openid profile email offline_access api.connectors.read api.connectors.invoke"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: state),
            .init(name: "originator", value: "codex_cli_rs"),
            .init(name: "prompt", value: "login"),   // 强制重新选择账号，避免浏览器里已登录的账号被直接带过
        ]
        authorizeURL = c.url!.absoluteString.replacingOccurrences(of: "+", with: "%2B")
    }

    /// 监听回调并换取 token，返回写成 auth.json 格式的文本
    func run() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                lock.lock(); cont = c; lock.unlock()
                do { try startListener() } catch { finish(.failure(error)) }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ r: Result<String, Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let c = cont; cont = nil
        lock.unlock()
        listener?.cancel(); listener = nil
        if let c { c.resume(with: r) }
    }

    private func startListener() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.finish(.failure(AppError(L("本机 1455 端口被占用（可能有 codex 登录正在进行），请稍后重试", "Port 1455 is in use (a codex login may be in progress). Please try again later")))) }
        }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: .global())
        listener = l
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8),
                  let line = req.split(separator: "\r\n").first else { conn.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let url = URLComponents(string: "http://127.0.0.1" + parts[1]) else { conn.cancel(); return }
            guard url.path == "/auth/callback" else { self.reply(conn, 404, "Not Found"); return }
            let q = Dictionary(url.queryItems?.compactMap { i in i.value.map { (i.name, $0) } } ?? [], uniquingKeysWith: { a, _ in a })
            if let err = q["error"] {
                self.reply(conn, 400, L(L("登录失败：\(q["error_description"] ?? err)，可以回到 SwitchBoard 重试。", "Login failed: \(q["error_description"] ?? err). You can go back to SwitchBoard and retry."), "Login failed: \(q["error_description"] ?? err). You can go back to SwitchBoard and retry."))
                self.finish(.failure(AppError(L("授权失败：\(q["error_description"] ?? err)", "Authorization failed: \(q["error_description"] ?? err)"))))
            } else if q["state"] != self.state {
                self.reply(conn, 400, "State mismatch")
            } else if let code = q["code"] {
                self.reply(conn, 200, L("登录成功，可以关闭此页面，回到 SwitchBoard。", "Login successful. You can close this page and return to SwitchBoard."))
                Task { self.finish(await self.exchange(code: code)) }
            } else {
                self.reply(conn, 400, L("缺少授权码", "Missing authorization code"))
            }
        }
    }

    private func reply(_ conn: NWConnection, _ status: Int, _ text: String) {
        let html = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><title>SwitchBoard</title>"
            + "<body style='font:16px -apple-system,sans-serif;display:grid;place-items:center;height:90vh;color:#222'><p>\(text)</p>"
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n"
        conn.send(content: Data((head + html).utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func exchange(code: String) async -> Result<String, Error> {
        var req = URLRequest(url: CodexService.tokenURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "authorization_code"), .init(name: "code", value: code),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "client_id", value: CodexService.clientID),
            .init(name: "code_verifier", value: verifier),
        ]
        req.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let idt = r["id_token"] as? String, let at = r["access_token"] as? String, let rt = r["refresh_token"] as? String
            else { return .failure(AppError(L("换取登录凭证失败（\((resp as? HTTPURLResponse)?.statusCode ?? 0)）", "Failed to exchange the login credentials (\((resp as? HTTPURLResponse)?.statusCode ?? 0))"))) }
            let claims = JWT.claims(idt)?["https://api.openai.com/auth"] as? [String: Any]
            var tokens: [String: Any] = ["id_token": idt, "access_token": at, "refresh_token": rt]
            if let a = claims?["chatgpt_account_id"] as? String { tokens["account_id"] = a }
            let auth: [String: Any] = ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "tokens": tokens, "last_refresh": CodexService.iso()]
            let d = try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return .success(String(decoding: d, as: UTF8.self))
        } catch { return .failure(error) }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

import Foundation

/// Codex 中转站：切换时改写 $CODEX_HOME/config.toml 里的 model_provider / model / model_catalog_json
/// 和 [model_providers.switchboard] 一节；其余内容原样保留。切回订阅账号时还原。
/// 不引入 TOML 库：只处理顶层的标量键和我们自己的那一节，按行编辑。
enum CodexConfig {
    static let providerID = "switchboard"
    private static let managedTop = ["model_provider", "model", "model_catalog_json"]
    private static let marker = "# switchboard:account="

    static var file: URL { CodexLive.home.appendingPathComponent("config.toml") }
    private static var restoreFile: URL { CodexLive.home.appendingPathComponent("switchboard-restore.json") }
    static var catalogDir: URL { CodexLive.home.appendingPathComponent("model-catalogs") }

    // MARK: 当前状态

    /// 当前生效的中转站账号 id（config.toml 里有我们的标记，且 model_provider 指向我们）
    static func activeAPIID() -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard topValue("model_provider", in: lines) == providerID else { return nil }
        return lines.first { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces) }
    }

    // MARK: 应用 / 还原

    static func applyAPI(_ acc: Account, key: String) throws {
        guard let api = acc.api else { return }
        var lines = (try? String(contentsOf: file, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        backupOnce()
        // 第一次接管时记下用户原来的这几项，切回订阅时还原
        if !FileManager.default.fileExists(atPath: restoreFile.path) {
            var saved: [String: Any] = [:]
            for k in managedTop { saved[k] = rawLine(k, in: lines) ?? NSNull() }
            try FileJSON.write(["top": saved], to: restoreFile)
        }
        removeBlock(&lines)

        setTop("model_provider", "\"\(providerID)\"", in: &lines)
        if !api.model.isEmpty { setTop("model", quote(api.model), in: &lines) }
        let names = api.catalogModels.filter { !$0.target.isEmpty }
        if api.catalog, !names.isEmpty {
            let url = try writeCatalog(for: acc, models: names)
            setTop("model_catalog_json", quote(url.path), in: &lines)
        } else {
            setTop("model_catalog_json", nil, in: &lines)   // 默认不开启模型映射
        }

        while lines.last?.isEmpty == true { lines.removeLast() }
        lines += ["", marker + acc.id, "[model_providers.\(providerID)]",
                  "name = \(quote(acc.name))",
                  "base_url = \(quote(api.baseURL))",
                  "wire_api = \"responses\"",
                  "requires_openai_auth = false",
                  "experimental_bearer_token = \(quote(key))", ""]
        try write(lines)
    }

    /// 只在是我们写入的（有标记）时才还原，不动用户自己手写的配置
    static func clearAPI() throws {
        guard activeAPIID() != nil, var lines = (try? String(contentsOf: file, encoding: .utf8))?.components(separatedBy: "\n") else { return }
        removeBlock(&lines)
        let top = (FileJSON.read(restoreFile)?["top"] as? [String: Any]) ?? [:]
        for k in managedTop {
            if let raw = top[k] as? String { setTopRaw(k, raw, in: &lines) } else { setTop(k, nil, in: &lines) }
        }
        try write(lines)
        try? FileManager.default.removeItem(at: restoreFile)
    }

    // MARK: 模型目录（实验性）

    /// 以 Codex 自己缓存的模型目录里的条目为模板，给每个模型名生成一条。
    /// 目录格式官方没有文档，是从 models_cache.json / 已有目录文件里的条目推断出来的，Codex 升级后可能失效。
    private static func writeCatalog(for acc: Account, models: [ModelMap]) throws -> URL {
        guard let pool = templateModels(), let fallback = pool.first else {
            throw AppError(L("找不到可用作模板的 Codex 模型目录（先运行一次 Codex 生成 ~/.codex/models_cache.json）",
                             "No Codex model catalog found to use as a template (run Codex once to create ~/.codex/models_cache.json)"))
        }
        var out: [[String: Any]] = []
        for (i, map) in models.enumerated() {
            // slug 是请求里发给中转站的模型名；display_name 是 Codex 里显示的名字。
            // 左边的名字若恰好是 Codex 认识的模型，就沿用它的元数据
            var m = pool.first { ($0["slug"] as? String) == map.name } ?? pool.first { ($0["slug"] as? String) == map.target } ?? fallback
            m["slug"] = map.target
            m["display_name"] = map.name.isEmpty ? map.target : map.name
            m["description"] = acc.name
            m["visibility"] = "list"
            m["priority"] = i + 1
            m["upgrade"] = NSNull()
            m["availability_nux"] = NSNull()
            out.append(m)
        }
        try FileManager.default.createDirectory(at: catalogDir, withIntermediateDirectories: true)
        let url = catalogDir.appendingPathComponent("switchboard-\(acc.id.prefix(8)).json")
        try FileJSON.write(["models": out], to: url)
        return url
    }

    private static func templateModels() -> [[String: Any]]? {
        var candidates = [CodexLive.home.appendingPathComponent("models_cache.json")]
        let others = (try? FileManager.default.contentsOfDirectory(at: catalogDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        candidates += others.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("switchboard-") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                      ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for u in candidates {
            if let ms = FileJSON.read(u)?["models"] as? [[String: Any]], !ms.isEmpty { return ms }
        }
        return nil
    }

    // MARK: 按行编辑 TOML

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func isHeader(_ l: String) -> Bool { l.trimmingCharacters(in: .whitespaces).hasPrefix("[") }

    /// 第一个表头之前的行是顶层键
    private static func topEnd(_ lines: [String]) -> Int { lines.firstIndex(where: isHeader) ?? lines.count }

    private static func keyIndex(_ key: String, in lines: [String]) -> Int? {
        lines[..<topEnd(lines)].firstIndex { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(key) else { return false }
            return t.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }
    }

    private static func rawLine(_ key: String, in lines: [String]) -> String? { keyIndex(key, in: lines).map { lines[$0] } }

    private static func topValue(_ key: String, in lines: [String]) -> String? {
        guard let raw = rawLine(key, in: lines), let eq = raw.firstIndex(of: "=") else { return nil }
        var v = raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if let hash = v.firstIndex(of: "#"), !v.hasPrefix("\"") { v = String(v[..<hash]).trimmingCharacters(in: .whitespaces) }
        if v.hasPrefix("\""), let end = v.dropFirst().firstIndex(of: "\"") { return String(v[v.index(after: v.startIndex)..<end]) }
        return v
    }

    private static func setTop(_ key: String, _ value: String?, in lines: inout [String]) {
        setTopRaw(key, value.map { "\(key) = \($0)" }, in: &lines)
    }

    private static func setTopRaw(_ key: String, _ raw: String?, in lines: inout [String]) {
        if let i = keyIndex(key, in: lines) {
            if let raw { lines[i] = raw } else { lines.remove(at: i) }
        } else if let raw {
            var at = topEnd(lines)
            while at > 0, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert(raw, at: at)
        }
    }

    /// 删掉我们的 [model_providers.switchboard…] 各节和前面的标记行
    private static func removeBlock(_ lines: inout [String]) {
        let head = "[model_providers.\(providerID)"
        var out: [String] = []
        var skipping = false
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(marker) { continue }
            if isHeader(l) { skipping = t.hasPrefix(head + "]") || t.hasPrefix(head + ".") }
            if !skipping { out.append(l) }
        }
        lines = out
    }

    private static func backupOnce() {
        let bak = file.appendingPathExtension("switchboard.bak")
        if FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: bak.path) {
            try? FileManager.default.copyItem(at: file, to: bak)
        }
    }

    /// 文件里有密钥：先以 0600 建好临时文件再覆盖原文件，不存在权限更宽的窗口，也不沿用原文件较宽的权限
    private static func write(_ lines: [String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: CodexLive.home, withIntermediateDirectories: true)
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".config.toml.switchboard.tmp")
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: Data(lines.joined(separator: "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw AppError(L("无法写入 \(tmp.path)", "Could not write \(tmp.path)"))
        }
        if fm.fileExists(atPath: file.path) {
            _ = try fm.replaceItemAt(file, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: file)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

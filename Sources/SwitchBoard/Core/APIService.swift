import Foundation

/// 自定义 API 账号没有额度接口，只探测连通性：
/// GET {baseURL}/v1/models —— 网络不通 / 401 / 403 / 5xx 视为异常，其余（含 404：站点没实现该接口）视为可连接。
enum APIService {
    private static func request(_ baseURL: String, key: String) -> URLRequest? {
        let base = baseURL.hasSuffix("/v1") ? baseURL : baseURL + "/v1"
        guard let url = URL(string: base + "/models") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return req
    }

    /// 拉取中转站的模型列表（Anthropic / OpenAI 风格都是 {"data":[{"id":…}]}）
    static func fetchModels(baseURL: String, key: String) async throws -> [String] {
        guard let req = request(baseURL, key: key) else { throw AppError(L("Base URL 无效", "Invalid Base URL")) }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw AppError(L("无法连接到该地址", "Cannot reach this address")) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AppError(code == 401 || code == 403 ? L("密钥无效或无权限（HTTP \(code)）", "Invalid key or no permission (HTTP \(code))")
                                                      : L("该站点不支持获取模型列表（HTTP \(code)），请手动输入", "This site does not list models (HTTP \(code)). Enter them manually"))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let arr = obj["data"] as? [[String: Any]] else {
            throw AppError(L("返回格式无法识别，请手动输入", "Unrecognized response. Enter models manually"))
        }
        let ids = arr.compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { throw AppError(L("模型列表为空，请手动输入", "The model list is empty. Enter models manually")) }
        return ids.sorted()
    }

    static func check(_ acc: Account) async -> AccountStatus? {
        guard let api = acc.api, let key = await Vault.shared.get(acc.id), !key.isEmpty else {
            return .error(L("缺少 API 密钥", "API key missing"))
        }
        guard let req = request(api.baseURL, key: key) else { return .error(L("Base URL 无效", "Invalid Base URL")) }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 401, 403: return .error(L("密钥无效或无权限（HTTP \(code)）", "Invalid key or no permission (HTTP \(code))"))
            case 500...: return .error(L("服务异常（HTTP \(code)）", "Server error (HTTP \(code))"))
            default: return nil
            }
        } catch {
            return .error(L("无法连接 \(api.host)", "Cannot reach \(api.host)"))
        }
    }
}

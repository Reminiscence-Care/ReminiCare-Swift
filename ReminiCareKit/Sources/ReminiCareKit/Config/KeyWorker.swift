import Foundation

/// Fetches service keys from the ReminiCare key Worker (`key-worker/`), so each
/// iPad needs only the Worker's token. The app still calls every service itself.
public enum KeyWorker {
    /// The only names accepted from the Worker; anything else in its answer is dropped.
    public static let distributed: Set<String> = [
        "NCKU_STT_TOKEN", "NCKU_TTS_TOKEN", ConfigKey.speechWorkerToken, "CLOUDFLARE_IMAGE_APP_TOKEN",
    ]

    public enum Failure: Error, Equatable {
        case notConfigured, unauthorized, rateLimited, server(Int), invalidResponse, network

        public var message: String {
            switch self {
            case .notConfigured: "請先填 Key Worker 網址和 Token"
            case .unauthorized: "Key Worker Token 錯誤"
            case .rateLimited: "太頻繁，請稍後再試"
            case .server(let code): "Key Worker 錯誤（HTTP \(code)）"
            case .invalidResponse: "Key Worker 回應格式不符"
            case .network: "連不上 Key Worker"
            }
        }
    }

    /// The Worker's keys, limited to `distributed` names with non-empty values.
    public static func fetch(baseURL: String, token: String, http: HTTPSending = URLSession.shared) async throws(Failure) -> [String: String] {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme == "https" || base.scheme == "http" else { throw .notConfigured }
        var request = URLRequest(url: base.appending(path: "v1/keys"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await HTTPTransport(client: http, timeout: .seconds(15), area: .settings).send(request)
        } catch {
            throw .network
        }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw .unauthorized
        case 429: throw .rateLimited
        default: throw .server(response.statusCode)
        }
        struct Body: Decodable { let keys: [String: String] }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw .invalidResponse }
        return body.keys.reduce(into: [:]) { result, pair in
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if distributed.contains(pair.key), !value.isEmpty { result[pair.key] = value }
        }
    }

    /// When the switch is on, fetches and saves the keys over the typed-in ones.
    /// On failure the keys already saved stay in use. Returns how many were saved.
    @discardableResult
    public static func refresh(config: ConfigStore = .shared, http: HTTPSending = URLSession.shared) async -> Int? {
        guard config.value(ConfigKey.keyWorkerEnabled) == "true" else { return nil }
        do {
            let keys = try await fetch(baseURL: config.value(ConfigKey.keyWorkerURL), token: config.value(ConfigKey.keyWorkerToken), http: http)
            try config.save(keys)
            AppLog.shared.record(.settings, .completed, complete: keys.count, total: keys.count, detail: "keyWorkerFetched")
            return keys.count
        } catch {
            AppLog.shared.record(.settings, .warning, detail: "keyWorkerFailed")
            return nil
        }
    }
}

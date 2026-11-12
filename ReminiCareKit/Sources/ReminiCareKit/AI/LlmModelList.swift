import Foundation

/// The models an OpenAI-compatible provider offers to this key (`GET {baseURL}/models`).
public enum LlmModelList {
    public enum Failure: Error, Equatable {
        case notConfigured, invalidKey, rateLimited, server(Int), invalidResponse, network

        public var message: String {
            switch self {
            case .notConfigured: "請先填網址和 Key"
            case .invalidKey: "Key 無效"
            case .rateLimited: "太頻繁或額度用完"
            case .server(let code): "服務錯誤（HTTP \(code)）"
            case .invalidResponse: "這個服務沒有提供模型清單，請手動輸入"
            case .network: "連不上服務"
            }
        }
    }

    public static func fetch(baseURL: String, apiKey: String, http: HTTPSending = URLSession.shared) async throws(Failure) -> [String] {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme == "https" || base.scheme == "http" else { throw .notConfigured }
        var request = URLRequest(url: base.appending(path: "models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await HTTPTransport(client: http, timeout: .seconds(20), area: .llm).send(request)
        } catch {
            throw .network
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw .invalidKey
        case 402, 429: throw .rateLimited
        case 404: throw .invalidResponse
        default: throw .server(response.statusCode)
        }
        struct Body: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw .invalidResponse }
        // Gemini lists "models/gemini-…" but its chat endpoint takes the bare name.
        let ids = body.data.map { $0.id.hasPrefix("models/") ? String($0.id.dropFirst(7)) : $0.id }
        return Array(Set(ids)).sorted()
    }
}

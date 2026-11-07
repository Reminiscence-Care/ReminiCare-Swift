import Foundation

public protocol LlmClient: Sendable {
    func complete(messages: [LlmMessage], temperature: Double, maxTokens: Int, jsonObject: Bool) async throws -> String
}

public extension LlmClient {
    func complete(_ messages: [LlmMessage], temperature: Double = 0.6, maxTokens: Int = 500, jsonObject: Bool = false) async throws -> String {
        try await complete(messages: messages, temperature: temperature, maxTokens: maxTokens, jsonObject: jsonObject)
    }
}

public struct OpenAICompatibleLlmClient: LlmClient {
    public let config: LlmProviderConfig
    public let apiKey: String
    private let transport: HTTPTransport

    public init(config: LlmProviderConfig, apiKey: String, client: HTTPSending = URLSession.shared) {
        self.config = config
        self.apiKey = apiKey
        transport = HTTPTransport(client: client, timeout: config.timeout, area: .llm)
    }

    public func complete(messages: [LlmMessage], temperature: Double, maxTokens: Int, jsonObject: Bool) async throws -> String {
        do {
            return try await perform(messages: messages, temperature: temperature, maxTokens: maxTokens, jsonObject: jsonObject)
        } catch {
            let status = (error as? AIServiceError)?.statusCode
            AppLog.shared.record(.llm, .failed, statusCode: status, detail: logDetail(error))
            throw error
        }
    }

    private func perform(messages: [LlmMessage], temperature: Double, maxTokens: Int, jsonObject: Bool) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AIServiceError(.configuration, "尚未設定此 Provider 的 API Key。")
        }
        guard let url = URL(string: trimmedBase(config.baseURL) + "/chat/completions") else {
            throw AIServiceError(.configuration, "LLM Base URL 格式不正確。")
        }
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "max_tokens": maxTokens,
        ]
        if jsonObject { body["response_format"] = ["type": "json_object"] }
        for (key, value) in providerOptions() { body[key] = value }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(HTTPTransport.jsonRequest(url, bearer: apiKey, body: body))
        } catch is TimeoutError {
            throw AIServiceError(.timeout, "AI 請求逾時。")
        } catch where isCancellation(error) {
            throw CancellationError()
        } catch {
            throw AIServiceError(.network, "無法連線至 AI Provider：\(error.localizedDescription)")
        }

        let status = response.statusCode
        switch status {
        case 401, 403:
            throw AIServiceError(.authentication, "API Key 無效或沒有模型權限。\(ProviderResponseParser.errorDetail(data))", statusCode: status)
        case 429:
            throw AIServiceError(.rateLimit, "API 使用量已達限制，請稍後再試。", statusCode: status)
        case 402:
            throw AIServiceError(.billing, "AI Provider 餘額不足或付款設定未完成。\(ProviderResponseParser.errorDetail(data))", statusCode: status)
        case 200..<300:
            break
        default:
            throw AIServiceError(.network, "Provider 回傳 HTTP \(status)。\(ProviderResponseParser.errorDetail(data))", statusCode: status)
        }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) else {
            throw AIServiceError(.invalidResponse, "無法解析 Provider 回應。")
        }
        if let text = ProviderResponseParser.messageText(decoded) { return text }
        let finish = ((decoded as? [String: Any])?["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String
        throw AIServiceError(
            .invalidResponse,
            finish == "length" ? "Provider 的輸出額度被推理內容用完，沒有產生最終答案。" : "Provider 沒有回傳文字內容。"
        )
    }

    private func providerOptions() -> [String: Any] {
        guard config.id == "nvidia" else { return [:] }
        let model = config.model.lowercased()
        if model.contains("glm-5.3") {
            return ["reasoning_effort": "low", "chat_template_kwargs": ["clear_thinking": true]]
        }
        if model.contains("deepseek-v4.1") { return ["reasoning_effort": "low"] }
        return [:]
    }
}

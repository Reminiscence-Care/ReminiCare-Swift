import Foundation

/// Outcome of a settings-page connection test.
public enum HealthStatus: String, Codable, Sendable {
    case ok, notConfigured, invalidKey, quotaExhausted, rateLimited, unreachable, serverError, slow, unverifiable

    public var label: String {
        switch self {
        case .ok: "可用"
        case .notConfigured: "尚未設定"
        case .invalidKey: "Key 無效或已過期"
        case .quotaExhausted: "額度用完或方案到期"
        case .rateLimited: "請求太頻繁"
        case .unreachable: "連不上"
        case .serverError: "服務回報錯誤"
        case .slow: "回應過慢"
        case .unverifiable: "Key 有效（額度未確認）"
        }
    }

    public var advice: String {
        switch self {
        case .ok: "連線與金鑰正常。"
        case .notConfigured: "請填入這個服務的 API Key 或 Token。"
        case .invalidKey: "請到服務後台確認 Key 是否正確、是否過期或被停用，再重新貼上。"
        case .quotaExhausted: "請到服務後台儲值或續約，或暫時改用其他服務。"
        case .rateLimited: "服務暫時限制請求次數，請稍後再試。"
        case .unreachable: "請確認 iPad 的網路；網路正常的話，可能是服務端故障。"
        case .serverError: "服務端錯誤或設定不正確（例如模型名稱、網址），請確認設定或稍後再試。"
        case .slow: "服務有回應但很慢，對話時可能要等很久或逾時。"
        case .unverifiable: "Key 可以使用；這個服務無法在不花費額度的情況下確認剩餘額度。"
        }
    }

    /// Usable for a conversation (possibly with unknown quota).
    public var isUsable: Bool { self == .ok || self == .unverifiable }

    var logCode: String { "health" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public enum ServiceKind: String, Codable, Sendable, CaseIterable {
    case llm, image, speechRecognition, speechSynthesis

    public var label: String {
        switch self {
        case .llm: "語言模型"
        case .image: "生圖"
        case .speechRecognition: "語音辨識"
        case .speechSynthesis: "語音合成"
        }
    }
}

public struct HealthResult: Codable, Sendable, Equatable {
    public var kind: ServiceKind
    /// Provider shown to the user, e.g. "OpenAI gpt-4o-mini".
    public var provider: String
    public var status: HealthStatus
    public var checkedAt: Date
    public var durationMs: Int
    public var statusCode: Int?
}

/// Cheapest possible request per provider: token or model-list endpoints where
/// they exist, otherwise a minimal request. Never generates an image. Only the
/// status and time are kept; response bodies are inspected and discarded.
public struct ServiceHealthChecker: Sendable {
    public let config: ConfigStore
    public var http: HTTPSending
    public var timeout: Duration = .seconds(20)

    public init(config: ConfigStore, http: HTTPSending = URLSession.shared) {
        self.config = config
        self.http = http
    }

    private var factory: ServiceFactory { ServiceFactory(config: config) }
    private var usesNcku: Bool { config.value(ConfigKey.speechProvider) == "ncku" }
    private func key(_ reference: String) -> String { config.value(reference).trimmingCharacters(in: .whitespacesAndNewlines) }

    public func providerName(_ kind: ServiceKind) -> String {
        switch kind {
        case .llm:
            let settings = factory.llmConfig()
            return "\(settings.displayName) \(settings.model)"
        case .image: return factory.imageConfig().displayName
        case .speechRecognition, .speechSynthesis: return usesNcku ? "成大 NCKU" : "雅婷"
        }
    }

    public func check(_ kind: ServiceKind) async -> HealthResult {
        let watch = Stopwatch()
        let (status, statusCode) = await run(kind)
        let result = HealthResult(
            kind: kind, provider: providerName(kind), status: status,
            checkedAt: Date(), durationMs: watch.milliseconds, statusCode: statusCode
        )
        AppLog.shared.record(
            .settings, status.isUsable ? .completed : .warning,
            durationMs: result.durationMs, statusCode: statusCode, detail: status.logCode
        )
        return result
    }

    private func run(_ kind: ServiceKind) async -> (HealthStatus, Int?) {
        switch kind {
        case .llm: await checkLlm()
        case .image: await checkImage()
        case .speechRecognition: usesNcku ? await checkNckuStt() : await checkYatingToken()
        case .speechSynthesis: usesNcku ? await checkNckuTts() : await checkYatingTts()
        }
    }

    // MARK: Providers

    private func checkLlm() async -> (HealthStatus, Int?) {
        var settings = factory.llmConfig()
        let apiKey = key(settings.apiKeyReference)
        guard !apiKey.isEmpty else { return (.notConfigured, nil) }
        settings.timeout = timeout
        let client = OpenAICompatibleLlmClient(config: settings, apiKey: apiKey, client: http)
        do {
            _ = try await client.complete([LlmMessage("user", "請只回覆 OK")], temperature: 0, maxTokens: 16)
            return (.ok, 200)
        } catch let error as AIServiceError {
            return (Self.status(for: error), error.statusCode)
        } catch {
            return (error is TimeoutError ? .slow : .unreachable, nil)
        }
    }

    static func status(for error: AIServiceError) -> HealthStatus {
        switch error.kind {
        case .authentication: .invalidKey
        case .billing: .quotaExhausted
        case .rateLimit: .rateLimited
        case .timeout: .slow
        // Authenticated and answered, just not in the expected shape.
        case .invalidResponse: .ok
        case .configuration: .notConfigured
        case .network: error.statusCode == nil ? .unreachable : .serverError
        case .unsupportedCapability, .cancelled: .unreachable
        }
    }

    private func checkImage() async -> (HealthStatus, Int?) {
        let settings = factory.imageConfig()
        let apiKey = key(settings.apiKeyReference)
        guard !apiKey.isEmpty else { return (.notConfigured, nil) }
        guard let base = URL(string: trimmedBase(settings.baseURL)), base.scheme == "https" else { return (.notConfigured, nil) }
        if settings.id == "cloudflare" {
            switch await send(URLRequest(url: base.appending(path: "health"))) {
            case .failure(let status): return (status, nil)
            case .success(let response) where response.code != 200: return (.serverError, response.code)
            case .success: break
            }
            // The Worker checks the token before anything else and rejects a
            // non-JSON body with 415, so this proves the token without
            // generating an image or touching the rate limiter.
            var probe = URLRequest(url: base.appending(path: "v1/images/generations"))
            probe.httpMethod = "POST"
            probe.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            probe.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            probe.httpBody = Data("health".utf8)
            switch await send(probe) {
            case .failure(let status): return (status, nil)
            case .success(let response):
                return switch response.code {
                case 415: (.ok, 415)
                case 401, 403: (.invalidKey, response.code)
                case 429: (.rateLimited, 429)
                default: (.serverError, response.code)
                }
            }
        }
        var request = URLRequest(url: base.appending(path: "models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        switch await send(request) {
        case .failure(let status): return (status, nil)
        case .success(let response):
            return switch response.code {
            // The key works; the balance cannot be read without spending it.
            case 200..<300, 404: (.unverifiable, response.code)
            case 401, 403: (.invalidKey, response.code)
            case 402: (.quotaExhausted, 402)
            case 429: (isQuotaExhausted(response.body) ? .quotaExhausted : .rateLimited, 429)
            default: (.serverError, response.code)
            }
        }
    }

    private func checkYatingToken() async -> (HealthStatus, Int?) {
        let apiKey = key("YATING_API_KEY")
        guard !apiKey.isEmpty, let request = try? yatingTokenRequest(apiKey: apiKey) else { return (.notConfigured, nil) }
        switch await send(request) {
        case .failure(let status): return (status, nil)
        case .success(let response) where response.code == 201: return (.ok, 201)
        case .success(let response):
            return (Self.status(forDetail: yatingTokenFailure(statusCode: response.code, body: response.body).detail), response.code)
        }
    }

    private func checkYatingTts() async -> (HealthStatus, Int?) {
        let apiKey = key("YATING_API_KEY")
        guard !apiKey.isEmpty else { return (.notConfigured, nil) }
        var synthesizer = YatingSpeechSynthesizer(apiKey: { apiKey })
        synthesizer.http = http
        let outcome = await synthesizer.synthesizeReporting("測試", language: .mandarin)
        if outcome.audio != nil { return (.ok, outcome.statusCode) }
        return (Self.status(forDetail: outcome.detail ?? "server"), outcome.statusCode)
    }

    private func checkNckuStt() async -> (HealthStatus, Int?) {
        let token = key("NCKU_STT_TOKEN")
        guard !token.isEmpty else { return (.notConfigured, nil) }
        let raw = config.value("NCKU_STT_URL")
        guard let endpoint = URL(string: raw.isEmpty ? ConfigKey.defaultNckuSttURL : raw) else { return (.notConfigured, nil) }
        var recognizer = NckuSpeechRecognizer(token: { token }, endpoint: endpoint)
        recognizer.http = http
        recognizer.timeout = timeout
        // Half a second of silence: the smallest valid request.
        let file = FileManager.default.temporaryDirectory.appending(path: "reminicare_health_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try WavAudio(pcm: Data(count: WavAudio.bytesPerSecond / 2)).encode().write(to: file)
            _ = try await recognizer.transcribe(file, progress: nil)
            return (.ok, 200)
        } catch let error as SttError {
            return (Self.status(forDetail: error.kind.rawValue), nil)
        } catch {
            return (.unreachable, nil)
        }
    }

    private func checkNckuTts() async -> (HealthStatus, Int?) {
        guard !key("NCKU_TTS_TOKEN").isEmpty else { return (.notConfigured, nil) }
        // Raw TCP: failures are logged by the synthesizer in detail.
        let audio = await factory.synthesizer().synthesize("測試", language: .mandarin)
        return (audio == nil ? .serverError : .ok, nil)
    }

    /// Maps the App Log codes used by the speech clients.
    static func status(forDetail detail: String) -> HealthStatus {
        switch detail {
        case "authentication": .invalidKey
        case "billing": .quotaExhausted
        case "rateLimit": .rateLimited
        case "timeout": .slow
        case "network", "cancelled": .unreachable
        default: .serverError
        }
    }

    // MARK: Transport

    private struct Response: Sendable {
        let code: Int
        let body: Data
    }

    private func send(_ request: URLRequest) async -> Result<Response, HealthStatus> {
        var timed = request
        timed.timeoutInterval = timeout.seconds
        let prepared = timed
        let http = http
        do {
            let (data, response) = try await withTimeout(timeout) { try await http.send(prepared) }
            return .success(Response(code: response.statusCode, body: data))
        } catch is TimeoutError {
            return .failure(.slow)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.slow)
        } catch {
            return .failure(.unreachable)
        }
    }
}

extension HealthStatus: Error {}

/// Last result per service and provider, so the settings page can show when
/// each was checked. Status and time only.
public struct HealthHistory {
    static let key = "serviceHealth.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> [HealthResult] {
        guard let data = defaults.data(forKey: Self.key),
              let results = try? JSONDecoder().decode([HealthResult].self, from: data) else { return [] }
        return results
    }

    public func latest(_ kind: ServiceKind, provider: String) -> HealthResult? {
        load().last { $0.kind == kind && $0.provider == provider }
    }

    public func save(_ result: HealthResult) {
        var results = load().filter { !($0.kind == result.kind && $0.provider == result.provider) }
        results.append(result)
        if let data = try? JSONEncoder().encode(Array(results.suffix(24))) { defaults.set(data, forKey: Self.key) }
    }
}

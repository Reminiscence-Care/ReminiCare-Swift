import Foundation

/// The ReminiCare speech Worker (`speech-worker/`): Yating recognition and
/// synthesis over plain HTTPS. The Worker holds the Yating key and opens the
/// Yating WebSocket itself, so networks that block WebSockets still work.
public struct SpeechWorkerEndpoint: Sendable {
    public let baseURL: String
    public let token: String

    public init(baseURL: String, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// `path` under the base URL; nil unless the base is an HTTPS URL.
    func url(_ path: String) -> URL? {
        guard let url = URL(string: trimmedBase(baseURL) + path), url.scheme == "https", url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    func request(_ path: String, method: String = "POST") -> URLRequest? {
        guard let url = url(path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The Worker's fixed error code, or "unknown".
    static func errorCode(_ data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let code = object?["error"] as? String ?? ""
        return AppLog.detailLabels["worker_\(code)"] == nil ? "unknown" : code
    }

    static func partial(_ data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["partial"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The recognition error for a Worker error code.
    static func sttError(code: String, partial: String) -> SttError {
        switch code {
        case "unauthorized": SttError(.authentication, "語音 Worker 的 App Token 不正確，請到設定頁確認。")
        case "misconfigured": SttError(.server, "語音 Worker 尚未設定雅婷 Key，請聯絡開發團隊。")
        case "quota": SttError(.authentication, "雅婷額度不足或方案已到期，請聯絡開發團隊。")
        case "upstream_auth": SttError(.authentication, "語音 Worker 上的雅婷 Key 無效，請聯絡開發團隊。")
        case "rate_limited", "upstream_rate_limit": SttError(.server, "語音辨識請求太頻繁，請稍後再試。")
        case "invalid_audio": SttError(.invalidAudio, "錄音格式不正確，請重新錄音。")
        case "too_large": SttError(.payloadTooLarge, "錄音太長，請分段回答。")
        case "timeout", "upstream_closed": SttError(.incomplete, "辨識尚未完整完成，請重試。", partialText: partial)
        case "upstream_timeout": SttError(.timeout, "雅婷語音辨識伺服器沒有回應，請稍後重試。")
        case "upstream_unreachable": SttError(.server, "語音 Worker 暫時連不上雅婷，請稍後重試。")
        default: SttError(.server, "雅婷辨識服務回報錯誤，請重試。")
        }
    }
}

public struct YatingWorkerRecognizer: SpeechRecognizer {
    public let endpoint: @Sendable () -> SpeechWorkerEndpoint
    public var http: HTTPSending = URLSession.shared
    /// Waiting after the Worker has streamed the audio to Yating in real time.
    public var completionTimeout: Duration = .seconds(45)

    public init(endpoint: @escaping @Sendable () -> SpeechWorkerEndpoint) { self.endpoint = endpoint }

    /// The Worker streams in real time (2,000 bytes per 62.5 ms), so the wait covers that too.
    func timeout(bytes: Int) -> Duration {
        .microseconds(62_500) * ((bytes + 1_999) / 2_000) + completionTimeout
    }

    public func transcribe(_ file: URL, progress: SttProgress?) async throws -> String {
        progress?(0, 1)
        let audio: WavAudio
        do { audio = try WavAudio.parse(Data(contentsOf: file)) } catch {
            AppLog.shared.record(.stt, .requestFailed, detail: "invalidAudio")
            throw SttError(.invalidAudio, "錄音或辨識回應格式不正確。")
        }
        guard var request = endpoint().request("/v1/transcribe") else {
            AppLog.shared.record(.stt, .requestFailed, detail: "configuration")
            throw SttError(.authentication, "語音 Worker 網址必須是 HTTPS，請到設定頁確認。")
        }
        let wait = timeout(bytes: audio.pcm.count)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio.pcm
        request.timeoutInterval = wait.seconds
        let prepared = request
        let http = http
        let watch = Stopwatch()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await withTimeout(wait) { try await http.send(prepared) }
        } catch is TimeoutError {
            AppLog.shared.record(.stt, .requestFailed, durationMs: watch.milliseconds, bytes: audio.pcm.count, detail: "timeout")
            throw SttError(.timeout, "語音辨識逾時，請重試。")
        } catch where isCancellation(error) {
            throw SttError(.cancelled, "已取消辨識。")
        } catch {
            AppLog.shared.record(.stt, .requestFailed, durationMs: watch.milliseconds, bytes: audio.pcm.count, detail: "network")
            throw SttError(.network, "無法連上語音辨識服務，請檢查網路後重試。")
        }
        guard response.statusCode == 200 else {
            let code = SpeechWorkerEndpoint.errorCode(data)
            AppLog.shared.record(
                .stt, .requestFailed, durationMs: watch.milliseconds, bytes: audio.pcm.count,
                statusCode: response.statusCode, detail: "worker_\(code)"
            )
            throw SpeechWorkerEndpoint.sttError(code: code, partial: SpeechWorkerEndpoint.partial(data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            AppLog.shared.record(.stt, .requestFailed, statusCode: response.statusCode, detail: "invalidResponse")
            throw SttError(.invalidResponse, "語音辨識回應格式不正確。")
        }
        let sentences = object["sentences"] as? Int ?? 0
        AppLog.shared.record(
            .stt, .requestCompleted, durationMs: watch.milliseconds, bytes: audio.pcm.count,
            complete: sentences, total: sentences, statusCode: response.statusCode, detail: "speechWorkerTranscribe"
        )
        progress?(1, 1)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct YatingWorkerSynthesizer: SpeechSynthesizer {
    public let endpoint: @Sendable () -> SpeechWorkerEndpoint
    public var http: HTTPSending = URLSession.shared

    public init(endpoint: @escaping @Sendable () -> SpeechWorkerEndpoint) { self.endpoint = endpoint }

    public func synthesize(_ text: String, language: SpeechLanguage) async -> Data? {
        await synthesizeReporting(text, language: language).audio
    }

    /// The audio, or the App Log code and HTTP status of the failure (also logged).
    func synthesizeReporting(_ text: String, language: SpeechLanguage) async -> (audio: Data?, detail: String?, statusCode: Int?) {
        guard !text.isEmpty else { return (nil, "invalidInput", nil) }
        guard var request = endpoint().request("/v1/speeches") else {
            AppLog.shared.record(.tts, .requestFailed, detail: "configuration")
            return (nil, "configuration", nil)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text, "language": language == .taiwanese ? "taiwanese" : "mandarin",
        ])
        request.timeoutInterval = 35
        let prepared = request
        let http = http
        do {
            let (data, response) = try await withTimeout(.seconds(35)) { try await http.send(prepared) }
            if response.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let encoded = object["audioContent"] as? String, let pcm = Data(base64Encoded: encoded), !pcm.isEmpty {
                return (WavAudio.wav(pcm: pcm, sampleRate: 16_000), nil, response.statusCode)
            }
            let detail = response.statusCode == 200 ? "emptyAudio" : "worker_\(SpeechWorkerEndpoint.errorCode(data))"
            AppLog.shared.record(.tts, .requestFailed, bytes: data.count, statusCode: response.statusCode, detail: detail)
            return (nil, detail, response.statusCode)
        } catch is TimeoutError {
            AppLog.shared.record(.tts, .requestFailed, detail: "timeout")
            return (nil, "timeout", nil)
        } catch {
            if isCancellation(error) { return (nil, "cancelled", nil) }
            AppLog.shared.record(.tts, .requestFailed, detail: "network")
            return (nil, "network", nil)
        }
    }
}

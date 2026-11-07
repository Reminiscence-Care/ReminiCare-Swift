import Foundation

/// Classifies a 5002 proxy error body into a whitelisted App Log code (never the raw text).
/// The proxy only forwards; when its backend is down it answers 500 with `{"error": "... Connection refused ..."}`.
public func nckuSttErrorDetail(statusCode: Int, body: String) -> String {
    func matches(_ pattern: String) -> Bool {
        body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    if matches("Connection refused|NewConnectionError|Failed to establish|No route to host") { return "sttBackendRefused" }
    if matches("Read ?timed ?out|ReadTimeout|ConnectTimeout|timed out") { return "sttBackendTimeout" }
    if body.range(of: #""error"\s*:"#, options: .regularExpression) != nil { return "sttBackendError" }
    switch statusCode {
    case 401, 403: return "authentication"
    case 413: return "payloadTooLarge"
    case 429: return "rateLimit"
    case 500...: return "server"
    default: return "invalidResponse"
    }
}

/// NCKU ASR proxy: 5-second segments, two concurrent uploads, halves a segment the server rejects as too large.
public struct NckuSpeechRecognizer: SpeechRecognizer {
    public static let maximumBodyBytes = 240 * 1024
    public let token: @Sendable () -> String
    public let endpoint: URL
    public var http: HTTPSending = URLSession.shared
    public var timeout: Duration = .seconds(60)

    public init(token: @escaping @Sendable () -> String, endpoint: URL) {
        self.token = token
        self.endpoint = endpoint
    }

    public func transcribe(_ file: URL, progress: SttProgress?) async throws -> String {
        guard !token().isEmpty else { throw SttError(.authentication, "請設定成大 STT Token。") }
        let audio: WavAudio
        do { audio = try WavAudio.parse(Data(contentsOf: file)) } catch {
            AppLog.shared.record(.stt, .failed, detail: "invalidAudio")
            throw SttError(.invalidAudio, "錄音格式不正確或音檔不完整。")
        }
        let segments = audio.split()
        AppLog.shared.record(.stt, .started, bytes: audio.pcm.count, total: segments.count)
        progress?(0, segments.count)
        let done = LockedValue(0)
        var texts = Array(repeating: "", count: segments.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func addNext() {
                guard next < segments.count else { return }
                let index = next
                next += 1
                group.addTask { (index, try await recognize(segments[index])) }
            }
            addNext()
            addNext()
            while let (index, text) = try await group.next() {
                texts[index] = text
                let complete = done.withValue { $0 += 1; return $0 }
                progress?(complete, segments.count)
                addNext()
            }
        }
        return texts.filter { !$0.isEmpty }.joined(separator: "，")
    }

    func body(for audio: WavAudio) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        func encode(_ text: String) -> String {
            (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text).replacingOccurrences(of: "%20", with: "+")
        }
        let fields = [("lang", "Chinese & Taiwanese"), ("token", token()), ("audio", audio.encode().base64EncodedString())]
        return Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }

    private func recognize(_ audio: WavAudio) async throws -> String {
        try Task.checkCancellation()
        let body = body(for: audio)
        if body.count > Self.maximumBodyBytes { return try await subdivide(audio) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout.seconds
        let prepared = request
        let watch = Stopwatch()
        let data: Data
        let response: HTTPURLResponse
        do {
            let http = http
            (data, response) = try await withTimeout(timeout) { try await http.send(prepared) }
        } catch is TimeoutError {
            AppLog.shared.record(.stt, .requestFailed, durationMs: watch.milliseconds, detail: "timeout")
            throw SttError(.timeout, "語音辨識逾時，請重試。")
        } catch where isCancellation(error) {
            throw SttError(.cancelled, "已取消辨識。")
        } catch {
            AppLog.shared.record(.stt, .requestFailed, durationMs: watch.milliseconds, detail: "network")
            throw SttError(.network, "語音辨識連線失敗，請重試。")
        }
        AppLog.shared.record(.stt, .requestCompleted, durationMs: watch.milliseconds, bytes: body.count, statusCode: response.statusCode)
        let text = String(decoding: data, as: UTF8.self)
        if response.statusCode == 413
            || (response.statusCode >= 400 && text.range(of: "413|Request Entity Too Large", options: [.regularExpression, .caseInsensitive]) != nil) {
            return try await subdivide(audio)
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw SttError(.authentication, "成大 STT Token 無效。")
        }
        if response.statusCode != 200 {
            let detail = nckuSttErrorDetail(statusCode: response.statusCode, body: text)
            AppLog.shared.record(.stt, .requestFailed, durationMs: watch.milliseconds, statusCode: response.statusCode, detail: detail)
            let message = switch detail {
            case "sttBackendRefused": "成大語音辨識伺服器目前連不上（伺服器端問題），請稍後再試或改用雅婷。"
            case "sttBackendTimeout": "成大語音辨識伺服器回應逾時（伺服器端問題），請稍後再試。"
            default: "成大語音辨識服務暫時失敗，請重試。"
            }
            throw SttError(.server, message)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sentence = object["sentence"] as? String else {
            AppLog.shared.record(.stt, .requestFailed, durationMs: watch.milliseconds, detail: "invalidResponse")
            throw SttError(.invalidResponse, "成大 STT 回傳格式不正確。")
        }
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "<{silent}>" ? "" : trimmed
    }

    private func subdivide(_ audio: WavAudio) async throws -> String {
        guard audio.pcm.count >= 2 * WavAudio.bytesPerSecond else {
            throw SttError(.payloadTooLarge, "成大 STT 仍拒絕短錄音，請稍後重試或切換語音服務。")
        }
        let middle = (audio.pcm.count / 4) * 2
        let first = try await recognize(WavAudio(pcm: audio.pcm.prefix(middle)))
        let second = try await recognize(WavAudio(pcm: audio.pcm.suffix(from: audio.pcm.startIndex + middle)))
        return [first, second].filter { !$0.isEmpty }.joined(separator: "，")
    }
}

import Foundation

/// One Yating ASR WebSocket session.
public protocol YatingChannel: Sendable {
    func send(_ data: Data) async throws
    /// Next text message; nil when the socket closed.
    func receive() async throws -> String?
    func close()
}

public struct URLSessionYatingChannel: YatingChannel {
    let task: URLSessionWebSocketTask
    public init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        task.resume()
    }
    public func send(_ data: Data) async throws { try await task.send(.data(data)) }
    public func receive() async throws -> String? {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(data: data, encoding: .utf8)
        @unknown default: return nil
        }
    }
    public func close() { task.cancel(with: .normalClosure, reason: nil) }
}

public struct YatingSpeechRecognizer: SpeechRecognizer {
    public let apiKey: @Sendable () -> String
    public var http: HTTPSending = URLSession.shared
    public var connect: @Sendable (URL) -> YatingChannel = { URLSessionYatingChannel(url: $0) }
    public var completionTimeout: Duration = .seconds(30)
    public var sendDelay: Duration = .microseconds(62_500)

    public init(apiKey: @escaping @Sendable () -> String) { self.apiKey = apiKey }

    private struct Transcript: Sendable {
        var full = ""
        var current = ""
        var partial: String { (full + current).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private enum Event { case ready, eof, none }

    public func transcribe(_ file: URL, progress: SttProgress?) async throws -> String {
        progress?(0, 1)
        let audio: WavAudio
        do { audio = try WavAudio.parse(Data(contentsOf: file)) } catch {
            throw SttError(.invalidAudio, "錄音或辨識回應格式不正確。")
        }
        let token = try await authToken()
        guard let url = URL(string: "wss://asr.api.yating.tw/ws/v1/?token=\(token)") else {
            throw SttError(.invalidResponse, "雅婷 STT 驗證回應不正確。")
        }
        let channel = connect(url)
        defer { channel.close() }
        let transcript = LockedValue(Transcript())

        @Sendable func handle(_ message: String?) throws -> Event {
            guard let message else {
                throw SttError(.incomplete, "辨識連線未完整結束，請重試。", partialText: transcript.current.partial)
            }
            guard let data = message.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SttError(.invalidResponse, "雅婷回傳格式不正確。")
            }
            if object["status"] as? String == "error" { throw SttError(.server, "雅婷辨識服務回報錯誤。") }
            var event = Event.none
            if object["status"] as? String == "ok" { event = .ready }
            if let pipe = object["pipe"] as? [String: Any] {
                transcript.withValue { state in
                    if let sentence = pipe["asr_sentence"] as? String { state.current = sentence }
                    if pipe["asr_final"] as? Bool == true {
                        state.full += state.current + "，"
                        state.current = ""
                    }
                }
                if pipe["asr_eof"] as? Bool == true { event = .eof }
            }
            return event
        }

        do {
            try await withTimeout(.seconds(5)) {
                while try handle(await channel.receive()) != .ready {}
            }
            let pcm = audio.pcm
            let delay = sendDelay
            let sender = Task {
                var offset = 0
                while offset < pcm.count, !Task.isCancelled {
                    let end = min(offset + 2000, pcm.count)
                    try await channel.send(pcm.subdata(in: offset..<end))
                    try await Task.sleep(for: delay)
                    offset = end
                }
                try await channel.send(Data())
            }
            defer { sender.cancel() }
            try await withTimeout(completionTimeout) {
                while try handle(await channel.receive()) != .eof {}
            }
        } catch let error as SttError {
            throw error
        } catch is TimeoutError {
            throw SttError(.incomplete, "辨識尚未完整完成，請重試。", partialText: transcript.current.partial)
        } catch where isCancellation(error) {
            throw SttError(.cancelled, "已取消辨識。")
        } catch {
            throw SttError(.network, "雅婷語音辨識失敗，請重試。", partialText: transcript.current.partial)
        }
        progress?(1, 1)
        return transcript.current.partial.replacingOccurrences(of: #"^[，\s]+|[，\s]+$"#, with: "", options: .regularExpression)
    }

    private func authToken() async throws -> String {
        var request = try HTTPTransport.jsonRequest(
            URL(string: "https://asr.api.yating.tw/v1/token")!,
            headers: ["key": apiKey()],
            body: ["pipeline": "asr-zh-tw-std"]
        )
        request.timeoutInterval = 10
        let prepared = request
        let data: Data
        let response: HTTPURLResponse
        do {
            let http = http
            (data, response) = try await withTimeout(.seconds(10)) { try await http.send(prepared) }
        } catch is TimeoutError {
            AppLog.shared.record(.stt, .requestFailed, detail: "timeout")
            throw SttError(.timeout, "雅婷語音辨識逾時。")
        } catch where isCancellation(error) {
            throw SttError(.cancelled, "已取消辨識。")
        } catch {
            AppLog.shared.record(.stt, .requestFailed, detail: "network")
            throw SttError(.network, "雅婷語音辨識失敗，請重試。")
        }
        guard response.statusCode == 201 else {
            let detail = switch response.statusCode {
            case 401, 403: "authentication"
            case 402: "billing"
            case 429: "rateLimit"
            case 500...: "server"
            default: "invalidResponse"
            }
            AppLog.shared.record(.stt, .requestFailed, statusCode: response.statusCode, detail: detail)
            throw SttError(.authentication, "雅婷 STT 驗證失敗。")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["success"] as? Bool == true, let token = object["auth_token"] as? String else {
            throw SttError(.invalidResponse, "雅婷 STT 驗證回應不正確。")
        }
        return token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
    }
}

/// Yating TTS v2: 16 kHz LINEAR16 PCM wrapped in a WAV header.
public struct YatingSpeechSynthesizer: SpeechSynthesizer {
    public let apiKey: @Sendable () -> String
    public var http: HTTPSending = URLSession.shared
    public init(apiKey: @escaping @Sendable () -> String) { self.apiKey = apiKey }

    public func synthesize(_ text: String, language: SpeechLanguage) async -> Data? {
        guard !text.isEmpty else { return nil }
        let body: [String: Any] = [
            "input": ["text": text, "type": "text"],
            "voice": ["model": language == .taiwanese ? "tai_female_1" : "zh_en_female_1", "speed": 1.0, "pitch": 1.0, "energy": 1.0],
            "audioConfig": ["encoding": "LINEAR16", "sampleRate": "16K"],
        ]
        do {
            var request = try HTTPTransport.jsonRequest(URL(string: "https://tts.api.yating.tw/v2/speeches/short")!, headers: ["key": apiKey()], body: body)
            request.timeoutInterval = 30
            let prepared = request
            let http = http
            let (data, response) = try await withTimeout(.seconds(30)) { try await http.send(prepared) }
            if response.statusCode == 200 || response.statusCode == 201,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let encoded = object["audioContent"] as? String, let pcm = Data(base64Encoded: encoded), !pcm.isEmpty {
                return WavAudio.wav(pcm: pcm, sampleRate: 16_000)
            }
            let detail = switch response.statusCode {
            case 401, 403: "authentication"
            case 402: "billing"
            case 429: "rateLimit"
            case 500...: "server"
            default: "invalidResponse"
            }
            AppLog.shared.record(.tts, .requestFailed, bytes: data.count, statusCode: response.statusCode, detail: detail)
            return nil
        } catch is TimeoutError {
            AppLog.shared.record(.tts, .requestFailed, detail: "timeout")
            return nil
        } catch {
            if !isCancellation(error) { AppLog.shared.record(.tts, .requestFailed, detail: "network") }
            return nil
        }
    }
}

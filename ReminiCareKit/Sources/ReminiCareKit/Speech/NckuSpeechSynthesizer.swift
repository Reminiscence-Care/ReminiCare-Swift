import Foundation

/// What to try after NCKU 9998 fails to read Taiwanese Hanzi directly.
public enum TaiwaneseTtsFallback: String, Sendable, CaseIterable {
    case llmThenLegacy = "llm_legacy"
    case llmOnly = "llm"
    case legacyOnly = "legacy"
    case off = "off"

    public var label: String {
        switch self {
        case .llmThenLegacy: "LLM 轉台羅 → 舊伺服器"
        case .llmOnly: "只用 LLM 轉台羅"
        case .legacyOnly: "只用舊伺服器（音質較差）"
        case .off: "不備援"
        }
    }

    public static func parse(_ raw: String?) -> TaiwaneseTtsFallback {
        TaiwaneseTtsFallback(rawValue: raw?.trimmingCharacters(in: .whitespaces) ?? "") ?? .llmThenLegacy
    }

    public var usesLlm: Bool { self == .llmThenLegacy || self == .llmOnly }
    public var usesLegacy: Bool { self == .llmThenLegacy || self == .legacyOnly }
}

/// Model used only for Tâi-lô conversion, separate from the chat model.
/// 2026-11-06: OpenAI gpt-4.1 took about 5 s per sentence with the best wording.
public enum TaiLoModelSettings {
    public static let followCurrent = "current"
    public static let defaultProvider = "openai"
    public static let providers: [(id: String, label: String)] = [
        ("openai", "OpenAI（建議）"),
        ("gemini", "Google Gemini"),
        ("groq", "Groq"),
        ("nvidia", "NVIDIA（目前很慢，不建議）"),
        (followCurrent, "跟隨上方語言模型"),
    ]
    static let defaultModels = ["openai": "gpt-4.1"]

    public static func parseProvider(_ raw: String?) -> String {
        let value = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        return providers.contains { $0.id == value } ? value : defaultProvider
    }

    public static func resolve(provider: String?, model: String?, current: LlmProviderConfig) -> LlmProviderConfig {
        let id = parseProvider(provider)
        var base = id == followCurrent ? current : ProviderRegistry.llmPresets[id]!
        let custom = model?.trimmingCharacters(in: .whitespaces) ?? ""
        base.model = custom.isEmpty ? (defaultModels[id] ?? base.model) : custom
        base.timeout = .seconds(25)
        return base
    }
}

public func containsHan(_ text: String) -> Bool {
    text.range(of: #"[\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}\x{20000}-\x{3134F}]"#, options: .regularExpression) != nil
}

/// Tidies LLM Tâi-lô; nil when it is not sendable plain romanization.
public func normalizeTaiLo(_ value: Any?) -> String? {
    guard var text = value as? String else { return nil }
    let punctuation: [(String, String)] = [
        ("，", ","), ("、", ","), ("；", ","), ("：", ","), ("。", "."), ("．", "."), ("…", "."), ("？", "?"), ("！", "!"),
        ("「", ""), ("」", ""), ("『", ""), ("』", ""), ("（", ""), ("）", ""), ("\"", ""), ("“", ""), ("”", ""),
    ]
    for (from, to) in punctuation { text = text.replacingOccurrences(of: from, with: to.isEmpty ? " " : "\(to) ") }
    text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #" ([,.?!])"#, with: "$1", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, !containsHan(text), !text.contains("@@@"), text.range(of: "[A-Za-z]", options: .regularExpression) != nil else {
        return nil
    }
    return text
}

public struct LlmTaiLoConverter: Sendable {
    public let client: LlmClient
    public init(client: LlmClient) { self.client = client }

    public func toTaiLo(_ text: String) async throws -> String? {
        let quoted = String(data: try JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)?.dropFirst().dropLast() ?? ""
        let raw = try await client.complete([
            LlmMessage("system", "你是臺灣台語（閩南語）語言專家，負責把文字轉成教育部「臺灣台語羅馬字拼音方案」（台羅）給語音合成使用。只輸出合法 JSON。"),
            LlmMessage("user",
                "把下面的文字轉成台羅。規則：\n"
                + "1. 輸入可能是華語或台語漢字；先改成自然、口語、長輩聽得懂的台語說法，意思不可增減。\n"
                + "2. 用調號標聲調（例如 á à â ā a̍ a̋），不要用數字調；第一、四聲不標。\n"
                + "3. 同一個詞的音節用連字號連接，詞與詞之間空一格；只寫本調，不標變調。\n"
                + "4. 不可出現任何漢字；人名、地名也要轉台羅，數字、日期、時間改成台語唸法。\n"
                + "5. 標點只用 , . ? !\n"
                + "6. 只回傳 {\"tailo\":\"...\"}，不要解釋。\n"
                + "文字：\(quoted)"),
        ], temperature: 0.1, maxTokens: min(max(text.count * 12, 1200), 6000), jsonObject: true)
        let data = try ProviderResponseParser.decodeJSONObject(raw, requiredKey: "tailo")
        return normalizeTaiLo(data["tailo"])
    }
}

/// NCKU VITS gateway (9998) with the Taiwanese fallback chain.
public final class NckuSpeechSynthesizer: SpeechSynthesizer, @unchecked Sendable {
    /// Up to three services in a row; must stay below the TTS cache timeout.
    public static let totalBudget: Duration = .seconds(140)
    /// After 9998 rejects Hanzi, skip the direct attempt for this long.
    public static let hanziRejectionMemory: TimeInterval = 600

    public let host: String
    public let port: Int
    public let tls: Bool
    public let token: @Sendable () -> String
    public let fallback: TaiwaneseTtsFallback
    public let taiLo: LlmTaiLoConverter?
    public var tcp: TCPExchanging = NetworkTCPExchange()
    public var legacyHost = "140.116.245.157"
    public var legacyPort = 10012
    private let hanziRejectedAt = LockedValue<Date?>(nil)

    public init(host: String, port: Int, tls: Bool, token: @escaping @Sendable () -> String, fallback: TaiwaneseTtsFallback, taiLo: LlmTaiLoConverter?) {
        self.host = host
        self.port = port
        self.tls = tls
        self.token = token
        self.fallback = fallback
        self.taiLo = taiLo
    }

    private struct Outcome {
        var audio: Data?
        /// The server answered but refused (status=false), so 9998 itself is reachable.
        var rejected = false
    }

    public func synthesize(_ text: String, language: SpeechLanguage) async -> Data? {
        guard !text.isEmpty, !text.contains("@@@") else {
            AppLog.shared.record(.tts, .failed, detail: "invalidInput")
            return nil
        }
        let deadline = ContinuousClock.now + Self.totalBudget
        func remaining() -> Duration { deadline - ContinuousClock.now }

        if language == .mandarin {
            return await vits(text, lang: "zh", speaker: "4793", timeout: remaining()).audio
        }
        let hasHan = containsHan(text)
        let skipDirect = hasHan && fallback != .off
            && (hanziRejectedAt.current.map { Date().timeIntervalSince($0) < Self.hanziRejectionMemory } ?? false)
        var reachable = true
        if !skipDirect {
            let direct = await vits(text, lang: "tw", speaker: "M04", timeout: remaining())
            if let audio = direct.audio {
                if hasHan { hanziRejectedAt.withValue { $0 = nil } }
                return audio
            }
            if direct.rejected && hasHan { hanziRejectedAt.withValue { $0 = Date() } }
            reachable = direct.rejected
        }
        if fallback == .off { return nil }

        if fallback.usesLlm && hasHan && reachable {
            if let taiLo {
                if let romanized = await convert(taiLo, text, timeout: remaining()), remaining() > .zero {
                    let retry = await vits(romanized, lang: "tw", speaker: "M04", timeout: remaining(), startDetail: "tailo")
                    if let audio = retry.audio { return audio }
                }
            } else {
                AppLog.shared.record(.tts, .warning, detail: "tailoSkipped")
            }
        }
        if fallback.usesLegacy && remaining() > .zero {
            return await legacy(text, timeout: remaining())
        }
        return nil
    }

    private func convert(_ converter: LlmTaiLoConverter, _ text: String, timeout: Duration) async -> String? {
        guard timeout > .zero else { return nil }
        let watch = Stopwatch()
        AppLog.shared.record(.tts, .warning, detail: "tailo")
        do {
            let result = try await withTimeout(timeout) { try await converter.toTaiLo(text) }
            if result == nil { AppLog.shared.record(.tts, .failed, durationMs: watch.milliseconds, detail: "invalidResponse") }
            return result
        } catch {
            AppLog.shared.record(.tts, .failed, durationMs: watch.milliseconds, detail: error is TimeoutError ? "timeout" : "invalidResponse")
            return nil
        }
    }

    private func vits(_ text: String, lang: String, speaker: String, timeout: Duration, startDetail: String? = nil) async -> Outcome {
        let watch = Stopwatch()
        AppLog.shared.record(.tts, .started, detail: startDetail ?? lang)
        guard timeout > .zero else {
            AppLog.shared.record(.tts, .failed, detail: "timeout")
            return Outcome()
        }
        do {
            let message = "10012@@@\(token())@@@\(lang)@@@\(speaker)@@@\(text)EOT"
            let data = try await tcp.exchange(host: host, port: port, tls: tls, payload: Data(message.utf8), timeout: timeout, maximumBytes: 50 * 1024 * 1024)
            guard !data.isEmpty, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLog.shared.record(.tts, .failed, durationMs: watch.milliseconds, detail: "invalidResponse")
                return Outcome()
            }
            if object["status"] as? Bool == true {
                guard let encoded = object["bytes"] as? String, let wav = Data(base64Encoded: encoded), !wav.isEmpty else {
                    AppLog.shared.record(.tts, .failed, durationMs: watch.milliseconds, detail: "invalidResponse")
                    return Outcome()
                }
                AppLog.shared.record(.tts, .completed, durationMs: watch.milliseconds, bytes: wav.count, detail: startDetail ?? lang)
                return Outcome(audio: wav)
            }
            AppLog.shared.record(.tts, .failed, durationMs: watch.milliseconds, detail: "server")
            return Outcome(rejected: true)
        } catch {
            AppLog.shared.record(.tts, .failed, durationMs: watch.milliseconds, detail: error is TimeoutError ? "timeout" : "network")
            return Outcome()
        }
    }

    /// Legacy HTS server: 4-byte big-endian length + `token@@@text@@@M04@@@taiwanese`, answers raw WAV.
    private func legacy(_ text: String, timeout: Duration) async -> Data? {
        let watch = Stopwatch()
        AppLog.shared.record(.tts, .warning, detail: "legacyServer")
        let payload = Data("\(token())@@@\(text)@@@M04@@@taiwanese".utf8)
        var packet = Data()
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { packet.append(contentsOf: $0) }
        packet.append(payload)
        do {
            let data = try await tcp.exchange(host: legacyHost, port: legacyPort, tls: false, payload: packet, timeout: timeout, maximumBytes: 50 * 1024 * 1024)
            let isWav = data.count > 44 && data.prefix(4) == Data("RIFF".utf8)
            AppLog.shared.record(.tts, isWav ? .completed : .failed, durationMs: watch.milliseconds, bytes: isWav ? data.count : nil, detail: isWav ? "legacyServer" : "invalidResponse")
            return isWav ? data : nil
        } catch {
            AppLog.shared.record(.tts, .failed, durationMs: watch.milliseconds, detail: error is TimeoutError ? "timeout" : "network")
            return nil
        }
    }
}

import Foundation

public struct ConfigField: Sendable, Identifiable {
    public let key: String
    public let displayName: String
    public let hint: String
    public let isSecure: Bool
    public let defaultValue: String?
    public var id: String { key }

    public init(_ key: String, _ displayName: String, hint: String, secure: Bool = true, default value: String? = nil) {
        self.key = key
        self.displayName = displayName
        self.hint = hint
        self.isSecure = secure
        self.defaultValue = value
    }
}

public enum ConfigKey {
    public static let llmProvider = "selectedLlmProvider"
    public static let speechProvider = "selectedSpeechProvider"
    public static let imageProvider = "selectedImageProvider"
    public static let taiLoProvider = "TAILO_LLM_PROVIDER"
    public static let taiLoModel = "TAILO_LLM_MODEL"
    public static let taiwaneseFallback = "NCKU_TW_TTS_FALLBACK"
    public static let introSilence = "VOICE_INTRO_SILENCE_SECONDS"
    public static let chatSilence = "VOICE_CHAT_SILENCE_SECONDS"
    public static let maxRecord = "VOICE_MAX_RECORD_LIMIT"
    public static let transcriptCorrection = "STT_LLM_CORRECTION"
    public static let transcriptConfirmation = "STT_CONFIRM_TRANSCRIPT"
    public static let nckuSttModel = "NCKU_STT_MODEL"
    public static let nckuSttToMandarin = "NCKU_STT_TO_MANDARIN"
    public static let appleSpeech = "STT_APPLE_ON_DEVICE"
    public static let errorReportURL = "ERROR_REPORT_URL"
    public static let defaultErrorReportURL = "https://reminicare-report-api.hding49.workers.dev"
    public static let defaultNckuSttURL = "http://140.116.245.149:5002/proxy"
    public static let defaultNckuTtsHost = "140.116.245.146"
    public static let speechWorkerURL = "SPEECH_WORKER_URL"
    public static let speechWorkerToken = "SPEECH_WORKER_TOKEN"
    public static let defaultSpeechWorkerURL = "https://reminicare-speech-api.hding49.workers.dev"
}

/// Where speech recognition and synthesis go.
public enum SpeechProvider: String, Sendable, CaseIterable {
    /// Yating through the ReminiCare speech Worker (default): plain HTTPS, key on the Worker.
    case yating
    /// Yating directly with this iPad's own key (needs WebSockets); for development.
    case yatingDirect
    case ncku

    public init(_ raw: String) { self = SpeechProvider(rawValue: raw) ?? .yating }

    public var label: String {
        switch self {
        case .yating: "雅婷（經 ReminiCare Worker）"
        case .yatingDirect: "雅婷（直連，自備 Key）"
        case .ncku: "成大 NCKU"
        }
    }
}

/// Settings snapshot plus persistence. Secrets live in the Keychain and never
/// in UserDefaults; every save is all-or-nothing.
public final class ConfigStore: @unchecked Sendable {
    public static let shared = ConfigStore()

    public static let secretKeys: Set<String> = [
        "NVIDIA_API_KEY", "GEMINI_API_KEY", "OPENAI_API_KEY", "SILICONFLOW_API_KEY",
        "CLOUDFLARE_IMAGE_APP_TOKEN", "CUSTOM_LLM_API_KEY", "CUSTOM_IMAGE_API_KEY",
        "NCKU_TTS_TOKEN", "NCKU_STT_TOKEN", "YATING_API_KEY", "GROQ_API_KEY", ConfigKey.speechWorkerToken,
    ]

    public static let fields: [ConfigField] = [
        ConfigField("NCKU_STT_URL", "成大 STT 端點（正式部署需 HTTPS）", hint: "https://...", secure: false, default: ConfigKey.defaultNckuSttURL),
        ConfigField("NCKU_TTS_HOST", "成大 TTS 主機", hint: "tts.example.org", secure: false, default: ConfigKey.defaultNckuTtsHost),
        ConfigField("NCKU_TTS_PORT", "成大 TTS Port（中文；台語固定 9986）", hint: "9998", secure: false, default: "9998"),
        ConfigField("NCKU_TTS_TLS", "成大 TTS 使用 TLS（true/false）", hint: "false", secure: false, default: "false"),
        ConfigField(ConfigKey.taiLoModel, "轉台羅模型（留白用預設）", hint: "gpt-4.1", secure: false),
        ConfigField(ConfigKey.introSilence, "自我介紹：說完後等待秒數（1–30）", hint: "3", secure: false, default: "3"),
        ConfigField(ConfigKey.chatSilence, "聊天／修圖：說完後等待秒數（1–30）", hint: "6", secure: false, default: "6"),
        ConfigField("NVIDIA_API_KEY", "NVIDIA API Key", hint: "nvapi-..."),
        ConfigField("GEMINI_API_KEY", "Gemini API Key", hint: "AIza..."),
        ConfigField("OPENAI_API_KEY", "OpenAI API Key", hint: "sk-..."),
        ConfigField("GROQ_API_KEY", "Groq API Key", hint: "gsk_..."),
        ConfigField("SILICONFLOW_API_KEY", "SiliconFlow API Key", hint: "sk-..."),
        ConfigField("CLOUDFLARE_IMAGE_APP_TOKEN", "Cloudflare Image App Token", hint: "與 Worker APP_API_TOKEN 相同的值"),
        ConfigField("CLOUDFLARE_IMAGE_WORKER_URL", "Cloudflare Image Worker URL", hint: "https://reminicare-image-api.<subdomain>.workers.dev", secure: false, default: "https://reminicare-image-api.hding49.workers.dev"),
        ConfigField("CUSTOM_LLM_API_KEY", "Custom LLM API Key", hint: "sk-..."),
        ConfigField("CUSTOM_IMAGE_API_KEY", "Custom Image API Key", hint: "sk-..."),
        ConfigField("NCKU_TTS_TOKEN", "NCKU TTS Token", hint: "Token..."),
        ConfigField("NCKU_STT_TOKEN", "NCKU STT Token", hint: "Token..."),
        ConfigField("YATING_API_KEY", "Yating TTS/STT Token", hint: "Token..."),
        ConfigField(ConfigKey.speechWorkerToken, "語音 Worker App Token", hint: "與 Worker APP_TOKEN 相同的值"),
        ConfigField(ConfigKey.speechWorkerURL, "語音 Worker 網址", hint: "https://reminicare-speech-api.<subdomain>.workers.dev", secure: false, default: ConfigKey.defaultSpeechWorkerURL),
        ConfigField("CUSTOM_LLM_BASE_URL", "Custom LLM Base URL", hint: "https://example.com/v1", secure: false),
        ConfigField("CUSTOM_LLM_MODEL", "Custom LLM 模型", hint: "model-name", secure: false),
        ConfigField("CUSTOM_IMAGE_BASE_URL", "Custom Image Base URL", hint: "https://example.com/v1", secure: false),
        ConfigField("CUSTOM_IMAGE_MODEL", "Custom 生圖模型", hint: "model-name", secure: false),
        ConfigField("NVIDIA_LLM_MODEL", "NVIDIA LLM 模型", hint: "deepseek-ai/deepseek-v4.1-flash", secure: false, default: "deepseek-ai/deepseek-v4.1-flash"),
        ConfigField("OPENAI_LLM_MODEL", "OpenAI LLM 模型", hint: "gpt-4o-mini", secure: false, default: "gpt-4o-mini"),
        ConfigField("GEMINI_LLM_MODEL", "Gemini LLM 模型", hint: "gemini-2.5-flash", secure: false, default: "gemini-2.5-flash"),
        ConfigField("GROQ_LLM_MODEL", "Groq LLM 模型", hint: "qwen/qwen3.8-27b", secure: false, default: "qwen/qwen3.8-27b"),
        ConfigField(ConfigKey.maxRecord, "最長錄音秒數", hint: "180", secure: false, default: "180"),
        ConfigField(ConfigKey.transcriptCorrection, "用 AI 校正辨識錯字", hint: "true", secure: false, default: "true"),
        ConfigField(ConfigKey.transcriptConfirmation, "生圖前確認辨識文字", hint: "false", secure: false, default: "false"),
        ConfigField(ConfigKey.nckuSttModel, "成大 STT 模型", hint: NckuSttModel.medical.rawValue, secure: false, default: NckuSttModel.medical.rawValue),
        ConfigField(ConfigKey.nckuSttToMandarin, "成大台語辨識結果用 AI 轉華語", hint: "true", secure: false, default: "true"),
        ConfigField(ConfigKey.appleSpeech, "國語辨識改用 Apple 離線辨識", hint: "false", secure: false, default: "false"),
        ConfigField(ConfigKey.errorReportURL, "錯誤回報網址", hint: "https://reminicare-report-api.<subdomain>.workers.dev", secure: false, default: ConfigKey.defaultErrorReportURL),
    ]

    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let state = LockedValue<(values: [String: String], revision: Int)>(([:], 0))

    public init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    /// In-memory snapshot, e.g. unsaved settings-form values for a connection
    /// test. Backed by a throwaway store so an accidental `save` cannot touch
    /// the real settings or Keychain.
    public init(values: [String: String]) {
        defaults = UserDefaults(suiteName: "reminicare.preview") ?? .standard
        secrets = MemorySecretStore()
        state.withValue {
            $0.values = values
            $0.revision = 1
        }
    }

    public var revision: Int { state.current.revision }
    public var snapshot: [String: String] { state.current.values }
    public func value(_ key: String) -> String { state.current.values[key] ?? "" }

    public func load() throws {
        do { try loadValues() } catch {
            AppLog.shared.record(.settings, .failed, detail: "load")
            AppLog.shared.record(.settings, .failed, detail: logDetail(error))
            throw error
        }
    }

    private func loadValues() throws {
        var snapshot: [String: String] = [:]
        for field in Self.fields {
            var value = Self.secretKeys.contains(field.key)
                ? try secrets.read(field.key) ?? ""
                : defaults.string(forKey: field.key) ?? ""
            if value.isEmpty, let fallback = field.defaultValue {
                value = fallback
                defaults.set(value, forKey: field.key)
            }
            snapshot[field.key] = value
        }
        snapshot[ConfigKey.llmProvider] = defaults.string(forKey: ConfigKey.llmProvider) ?? "nvidia"
        snapshot[ConfigKey.speechProvider] = SpeechProvider(defaults.string(forKey: ConfigKey.speechProvider) ?? "").rawValue
        snapshot[ConfigKey.imageProvider] = defaults.string(forKey: ConfigKey.imageProvider) ?? "cloudflare"
        snapshot[ConfigKey.taiLoProvider] = TaiLoModelSettings.parseProvider(defaults.string(forKey: ConfigKey.taiLoProvider))
        snapshot[ConfigKey.taiwaneseFallback] = TaiwaneseTtsFallback.parse(defaults.string(forKey: ConfigKey.taiwaneseFallback)).rawValue
        state.withValue {
            $0.values = snapshot
            $0.revision += 1
        }
        AppLog.shared.record(.settings, .completed)
    }

    /// Writes every value or none: on failure the previous values are restored.
    public func save(_ values: [String: String]) throws {
        var previous: [String: String?] = [:]
        for key in values.keys {
            previous[key] = Self.secretKeys.contains(key) ? try secrets.read(key) : defaults.string(forKey: key)
        }
        do {
            for (key, raw) in values {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.secretKeys.contains(key) {
                    if value.isEmpty { try secrets.delete(key) } else { try secrets.write(key, value: value) }
                    defaults.removeObject(forKey: key)
                } else {
                    defaults.set(value, forKey: key)
                }
            }
        } catch {
            for (key, old) in previous {
                if Self.secretKeys.contains(key) {
                    if let old { try? secrets.write(key, value: old) } else { try? secrets.delete(key) }
                } else if let old {
                    defaults.set(old, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            AppLog.shared.record(.settings, .failed, detail: "save")
            AppLog.shared.record(.settings, .failed, detail: logDetail(error))
            throw error
        }
        state.withValue {
            for (key, value) in values {
                $0.values[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            $0.revision += 1
        }
        AppLog.shared.record(.settings, .completed)
    }

    /// Identity of everything that changes synthesized audio; part of the TTS cache key.
    public var ttsCacheIdentity: String {
        let fallback = TaiwaneseTtsFallback.parse(value(ConfigKey.taiwaneseFallback)).rawValue
        let taiLo = TaiLoModelSettings.parseProvider(value(ConfigKey.taiLoProvider))
        // Direct and Worker Yating use the same voices, so they share cached audio.
        let speech = SpeechProvider(value(ConfigKey.speechProvider)) == .ncku ? "ncku" : "yating"
        return "\(speech)|\(value("NCKU_TTS_HOST"))|\(value("NCKU_TTS_PORT"))|"
            + "tw:9986/0|zh:4793|yating:tw=tai_female_1,zh=zh_en_female_1|"
            + "tw-fallback:\(fallback)|tailo:\(taiLo)/\(value(ConfigKey.taiLoModel).trimmingCharacters(in: .whitespaces))"
    }

    /// The speech Worker's address and app token.
    public var speechWorker: SpeechWorkerEndpoint {
        let url = value(ConfigKey.speechWorkerURL)
        return SpeechWorkerEndpoint(
            baseURL: url.isEmpty ? ConfigKey.defaultSpeechWorkerURL : url,
            token: value(ConfigKey.speechWorkerToken)
        )
    }

    public var maxRecordSeconds: Int { Int(value(ConfigKey.maxRecord)) ?? 180 }

    /// LLM correction of answers and revision requests (on unless turned off).
    public var transcriptCorrectionEnabled: Bool { value(ConfigKey.transcriptCorrection) != "false" }
    /// Show the recognized text for confirmation before making an image (off unless turned on).
    public var transcriptConfirmationEnabled: Bool { value(ConfigKey.transcriptConfirmation) == "true" }
    public var nckuSttModel: NckuSttModel { NckuSttModel.parse(value(ConfigKey.nckuSttModel)) }
    /// NCKU's medical model writes Taiwanese as Taiwanese Hanzi; translate answers to Mandarin (on unless turned off).
    /// Recognition by Apple's on-device zh-TW model instead of the speech service (playback is unchanged).
    public var usesAppleSpeech: Bool { value(ConfigKey.appleSpeech) == "true" }
    public var translatesTranscriptToMandarin: Bool {
        !usesAppleSpeech && SpeechProvider(value(ConfigKey.speechProvider)) == .ncku && nckuSttModel == .medical
            && value(ConfigKey.nckuSttToMandarin) != "false"
    }

    public func silenceSeconds(introduction: Bool) -> Double {
        Double(value(introduction ? ConfigKey.introSilence : ConfigKey.chatSilence)) ?? (introduction ? 3 : 6)
    }

    /// Returns a user-facing problem with the settings, or nil when valid.
    public func validate(_ values: [String: String]) -> String? {
        func read(_ key: String) -> String {
            (values[key] ?? value(key)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let maximum = Int(read(ConfigKey.maxRecord).isEmpty ? "180" : read(ConfigKey.maxRecord))
        guard let maximum, (15...600).contains(maximum) else { return "最長錄音需為 15–600 秒的整數" }
        for key in [ConfigKey.introSilence, ConfigKey.chatSilence] {
            var raw = read(key)
            if raw.isEmpty && values[key] == nil { raw = key == ConfigKey.introSilence ? "3" : "6" }
            let valid = raw.range(of: #"^\d+(\.\d)?$"#, options: .regularExpression) != nil
            guard valid, let number = Double(raw), (1...30).contains(number) else {
                return "\(key == ConfigKey.introSilence ? "自我介紹" : "聊天／修圖")等待時間需為 1–30 秒，最多小數一位"
            }
        }
        let llm = read(ConfigKey.llmProvider).isEmpty ? "nvidia" : read(ConfigKey.llmProvider)
        let image = read(ConfigKey.imageProvider).isEmpty ? "cloudflare" : read(ConfigKey.imageProvider)
        let speech = SpeechProvider(read(ConfigKey.speechProvider))
        if read(Self.llmKey(llm)).isEmpty { return "目前語言模型的 API Key 不可空白" }
        if read(Self.imageKey(image)).isEmpty { return "目前生圖服務的 API Key 不可空白" }
        if read(Self.llmModelKey(llm)).isEmpty { return "目前語言模型名稱不可空白" }
        switch speech {
        case .ncku:
            if read("NCKU_TTS_TOKEN").isEmpty || read("NCKU_STT_TOKEN").isEmpty {
                return "NCKU 語音服務需要 TTS 與 STT Token"
            }
            let url = URL(string: read("NCKU_STT_URL").isEmpty ? ConfigKey.defaultNckuSttURL : read("NCKU_STT_URL"))
            guard let url, ["http", "https"].contains(url.scheme ?? ""), !(url.host ?? "").isEmpty else {
                return "成大 STT 端點格式不正確"
            }
            guard let port = Int(read("NCKU_TTS_PORT").isEmpty ? "9998" : read("NCKU_TTS_PORT")), (1...65535).contains(port) else {
                return "成大 TTS Port 格式不正確"
            }
            if !["true", "false", ""].contains(read("NCKU_TTS_TLS")) { return "成大 TTS TLS 請填 true 或 false" }
            if read("NCKU_TTS_HOST").rangeOfCharacter(from: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/"))) != nil {
                return "成大 TTS 主機請填主機名稱或 IP"
            }
        case .yatingDirect:
            if read("YATING_API_KEY").isEmpty { return "雅婷語音服務 Token 不可空白" }
        case .yating:
            if read(ConfigKey.speechWorkerToken).isEmpty { return "語音 Worker App Token 不可空白" }
            let raw = read(ConfigKey.speechWorkerURL).isEmpty ? ConfigKey.defaultSpeechWorkerURL : read(ConfigKey.speechWorkerURL)
            let url = URL(string: raw)
            if url?.scheme != "https" || (url?.host ?? "").isEmpty { return "語音 Worker 網址必須是有效的 HTTPS 網址" }
        }
        if llm == "custom", let error = Self.validateCustom(read("CUSTOM_LLM_BASE_URL"), read("CUSTOM_LLM_MODEL")) {
            return "自訂 LLM：\(error)"
        }
        if image == "custom", let error = Self.validateCustom(read("CUSTOM_IMAGE_BASE_URL"), read("CUSTOM_IMAGE_MODEL")) {
            return "自訂生圖：\(error)"
        }
        if image == "cloudflare" {
            let url = URL(string: read("CLOUDFLARE_IMAGE_WORKER_URL"))
            if url?.scheme != "https" || (url?.host ?? "").isEmpty {
                return "Cloudflare Worker URL 必須是有效的 HTTPS 網址"
            }
        }
        return nil
    }

    public static func llmKey(_ provider: String) -> String {
        switch provider {
        case "openai": "OPENAI_API_KEY"
        case "gemini": "GEMINI_API_KEY"
        case "groq": "GROQ_API_KEY"
        case "custom": "CUSTOM_LLM_API_KEY"
        default: "NVIDIA_API_KEY"
        }
    }

    public static func llmModelKey(_ provider: String) -> String {
        switch provider {
        case "openai": "OPENAI_LLM_MODEL"
        case "gemini": "GEMINI_LLM_MODEL"
        case "groq": "GROQ_LLM_MODEL"
        case "custom": "CUSTOM_LLM_MODEL"
        default: "NVIDIA_LLM_MODEL"
        }
    }

    public static func imageKey(_ provider: String) -> String {
        switch provider {
        case "cloudflare": "CLOUDFLARE_IMAGE_APP_TOKEN"
        case "openai": "OPENAI_API_KEY"
        case "custom": "CUSTOM_IMAGE_API_KEY"
        default: "SILICONFLOW_API_KEY"
        }
    }

    private static func validateCustom(_ rawURL: String, _ model: String) -> String? {
        let url = URL(string: rawURL)
        if url?.scheme != "https" || (url?.host ?? "").isEmpty { return "Base URL 必須是有效的 HTTPS 網址" }
        if model.isEmpty { return "模型名稱不可空白" }
        return nil
    }
}

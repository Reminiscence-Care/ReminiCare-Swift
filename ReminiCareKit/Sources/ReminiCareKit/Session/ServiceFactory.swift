import Foundation

/// Builds providers from the current settings.
public struct ServiceFactory: Sendable {
    public let config: ConfigStore
    public init(config: ConfigStore = .shared) { self.config = config }

    public func llmConfig() -> LlmProviderConfig {
        let id = config.value(ConfigKey.llmProvider)
        if id == "custom" {
            return LlmProviderConfig(
                id: "custom", displayName: "Custom OpenAI-compatible",
                baseURL: config.value("CUSTOM_LLM_BASE_URL"), model: config.value("CUSTOM_LLM_MODEL"),
                apiKeyReference: "CUSTOM_LLM_API_KEY", isCustom: true
            )
        }
        var preset = ProviderRegistry.llmPresets[id] ?? ProviderRegistry.llmPresets["nvidia"]!
        let model = config.value(ConfigStore.llmModelKey(preset.id)).trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { preset.model = model }
        return preset
    }

    /// The chosen model first, then every other preset with a key as backup.
    public func llm() -> LlmClient {
        let settings = llmConfig()
        var entries = [FallbackLlmClient.Entry(
            providerId: settings.id,
            client: OpenAICompatibleLlmClient(config: settings, apiKey: config.value(settings.apiKeyReference))
        )]
        for id in FallbackLlmClient.backupOrder where id != settings.id {
            guard var preset = ProviderRegistry.llmPresets[id] else { continue }
            let key = config.value(preset.apiKeyReference).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let model = config.value(ConfigStore.llmModelKey(id)).trimmingCharacters(in: .whitespaces)
            if !model.isEmpty { preset.model = model }
            entries.append(.init(providerId: id, client: OpenAICompatibleLlmClient(config: preset, apiKey: key)))
        }
        return FallbackLlmClient(entries)
    }

    public func reminiscenceAI() -> ReminiscenceAI { ReminiscenceAI(client: llm()) }

    public func imageConfig() -> ImageProviderConfig {
        let id = config.value(ConfigKey.imageProvider)
        if id == "custom" {
            return ImageProviderConfig(
                id: "custom", displayName: "Custom OpenAI-compatible",
                baseURL: config.value("CUSTOM_IMAGE_BASE_URL"), generationModel: config.value("CUSTOM_IMAGE_MODEL"),
                apiKeyReference: "CUSTOM_IMAGE_API_KEY", capabilities: [.imageGeneration], isCustom: true
            )
        }
        var preset = ProviderRegistry.imagePresets[id] ?? ProviderRegistry.imagePresets["cloudflare"]!
        if preset.id == "cloudflare" { preset.baseURL = config.value("CLOUDFLARE_IMAGE_WORKER_URL") }
        return preset
    }

    public func image() -> ImageGenerating {
        let settings = imageConfig()
        let key = config.value(settings.apiKeyReference)
        return settings.id == "cloudflare"
            ? CloudflareWorkerImageClient(config: settings, appToken: key)
            : OpenAICompatibleImageClient(config: settings, apiKey: key)
    }

    private var speech: SpeechProvider { SpeechProvider(config.value(ConfigKey.speechProvider)) }
    private var usesNcku: Bool { speech == .ncku }

    /// Every recognizer gets one automatic retry of the same recording.
    public func recognizer() -> SpeechRecognizer {
        RetryingSpeechRecognizer(baseRecognizer())
    }

    func baseRecognizer() -> SpeechRecognizer {
        let config = config
        switch speech {
        case .ncku:
            let raw = config.value("NCKU_STT_URL")
            let endpoint = URL(string: raw.isEmpty ? ConfigKey.defaultNckuSttURL : raw) ?? URL(string: ConfigKey.defaultNckuSttURL)!
            var recognizer = NckuSpeechRecognizer(token: { config.value("NCKU_STT_TOKEN") }, endpoint: endpoint)
            recognizer.model = config.nckuSttModel
            return recognizer
        case .yatingDirect:
            return YatingSpeechRecognizer(apiKey: { config.value("YATING_API_KEY") })
        case .yating:
            return YatingWorkerRecognizer(endpoint: { config.speechWorker })
        }
    }

    public func synthesizer() -> SpeechSynthesizer {
        let config = config
        switch speech {
        case .yating: return YatingWorkerSynthesizer(endpoint: { config.speechWorker })
        case .yatingDirect: return YatingSpeechSynthesizer(apiKey: { config.value("YATING_API_KEY") })
        case .ncku: break
        }
        let host = config.value("NCKU_TTS_HOST")
        return NckuSpeechSynthesizer(
            host: host.isEmpty ? ConfigKey.defaultNckuTtsHost : host,
            port: Int(config.value("NCKU_TTS_PORT")) ?? 9998,
            tls: config.value("NCKU_TTS_TLS") == "true",
            token: { config.value("NCKU_TTS_TOKEN") },
            fallback: TaiwaneseTtsFallback.parse(config.value(ConfigKey.taiwaneseFallback)),
            taiLo: taiLoConverter()
        )
    }

    /// Nil when the Tâi-lô model has no API key, so that step is skipped.
    func taiLoConverter() -> LlmTaiLoConverter? {
        let settings = TaiLoModelSettings.resolve(
            provider: config.value(ConfigKey.taiLoProvider), model: config.value(ConfigKey.taiLoModel), current: llmConfig()
        )
        let key = config.value(settings.apiKeyReference)
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return LlmTaiLoConverter(client: OpenAICompatibleLlmClient(config: settings, apiKey: key))
    }

    /// Message for missing settings that block starting a session, or nil.
    public func missingConfiguration() -> String? {
        let llm = config.value(ConfigKey.llmProvider)
        let image = config.value(ConfigKey.imageProvider)
        if config.value(ConfigStore.llmKey(llm)).isEmpty { return "請設定目前 LLM Provider 的 API Key。" }
        if config.value(ConfigStore.imageKey(image)).isEmpty { return "請設定目前生圖 Provider 的 API Key。" }
        let speechReady = switch speech {
        case .ncku: !config.value("NCKU_STT_TOKEN").isEmpty && !config.value("NCKU_TTS_TOKEN").isEmpty
        case .yatingDirect: !config.value("YATING_API_KEY").isEmpty
        case .yating: !config.value(ConfigKey.speechWorkerToken).isEmpty
        }
        if !speechReady { return "請設定目前語音服務需要的 Token。" }
        return config.validate([:])
    }
}

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

    public func llm() -> LlmClient {
        let settings = llmConfig()
        return OpenAICompatibleLlmClient(config: settings, apiKey: config.value(settings.apiKeyReference))
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

    private var usesNcku: Bool { config.value(ConfigKey.speechProvider) == "ncku" }

    public func recognizer() -> SpeechRecognizer {
        let config = config
        if usesNcku {
            let raw = config.value("NCKU_STT_URL")
            let endpoint = URL(string: raw.isEmpty ? ConfigKey.defaultNckuSttURL : raw) ?? URL(string: ConfigKey.defaultNckuSttURL)!
            return NckuSpeechRecognizer(token: { config.value("NCKU_STT_TOKEN") }, endpoint: endpoint)
        }
        return YatingSpeechRecognizer(apiKey: { config.value("YATING_API_KEY") })
    }

    public func synthesizer() -> SpeechSynthesizer {
        let config = config
        guard usesNcku else { return YatingSpeechSynthesizer(apiKey: { config.value("YATING_API_KEY") }) }
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
        let speechReady = usesNcku
            ? !config.value("NCKU_STT_TOKEN").isEmpty && !config.value("NCKU_TTS_TOKEN").isEmpty
            : !config.value("YATING_API_KEY").isEmpty
        if !speechReady { return "請設定目前語音服務需要的 Token。" }
        return config.validate([:])
    }
}

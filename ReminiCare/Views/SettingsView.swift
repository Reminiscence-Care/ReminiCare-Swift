import ReminiCareKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let config = ConfigStore.shared
    @State private var values: [String: String] = [:]
    @State private var llm = "nvidia"
    @State private var image = "cloudflare"
    @State private var speech = "yating"
    @State private var fallback = TaiwaneseTtsFallback.llmThenLegacy
    @State private var taiLoProvider = TaiLoModelSettings.defaultProvider
    @State private var saving = false
    @State private var validationError: String?

    private var visibleKeys: [String] {
        var keys = [ConfigStore.llmKey(llm), ConfigStore.llmModelKey(llm), ConfigStore.imageKey(image)]
        if speech == "ncku" {
            keys += ["NCKU_TTS_TOKEN", "NCKU_STT_TOKEN"]
            if fallback.usesLlm {
                keys.append(ConfigKey.taiLoModel)
                keys.append(taiLoProvider == TaiLoModelSettings.followCurrent
                    ? ConfigStore.llmKey(llm)
                    : ConfigStore.llmKey(taiLoProvider))
            }
        } else {
            keys.append("YATING_API_KEY")
        }
        keys += [ConfigKey.maxRecord, ConfigKey.introSilence, ConfigKey.chatSilence]
        if llm == "custom" { keys.append("CUSTOM_LLM_BASE_URL") }
        if image == "custom" { keys += ["CUSTOM_IMAGE_BASE_URL", "CUSTOM_IMAGE_MODEL"] }
        if image == "cloudflare" { keys.append("CLOUDFLARE_IMAGE_WORKER_URL") }
        return keys
    }

    private var llmInfo: String {
        switch llm {
        case "nvidia": "https://integrate.api.nvidia.com/v1"
        case "openai": "https://api.openai.com/v1"
        case "gemini": "https://generativelanguage.googleapis.com/v1beta/openai"
        default: "自訂 OpenAI-compatible 端點與模型"
        }
    }

    private var imageInfo: String {
        switch image {
        case "cloudflare": "FLUX.2 Klein 4B（支援生成與改圖，透過安全 Worker）"
        case "siliconflow": "https://api.siliconflow.com/v1  •  Qwen/Qwen-Image（支援改圖）"
        case "openai": "https://api.openai.com/v1  •  gpt-image-2"
        default: "自訂 OpenAI-compatible 端點（僅標準生成）"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("語言模型", selection: $llm) {
                        Text("NVIDIA").tag("nvidia")
                        Text("OpenAI").tag("openai")
                        Text("Google Gemini").tag("gemini")
                        Text("Custom OpenAI-compatible").tag("custom")
                    }
                    Text("LLM：\(llmInfo)").font(.footnote).foregroundStyle(.secondary)
                    Picker("生圖服務", selection: $image) {
                        Text("Cloudflare Workers AI（支援改圖）").tag("cloudflare")
                        Text("SiliconFlow（支援改圖）").tag("siliconflow")
                        Text("OpenAI").tag("openai")
                        Text("Custom OpenAI-compatible（僅生成）").tag("custom")
                    }
                    Text("生圖：\(imageInfo)").font(.footnote).foregroundStyle(.secondary)
                    Picker("語音服務", selection: $speech) {
                        Text("雅婷").tag("yating")
                        Text("成大 NCKU").tag("ncku")
                    }
                    if speech == "ncku" {
                        Picker("台語語音備援", selection: $fallback) {
                            ForEach(TaiwaneseTtsFallback.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        if fallback.usesLlm {
                            Picker("轉台羅使用的語言模型", selection: $taiLoProvider) {
                                ForEach(TaiLoModelSettings.providers, id: \.id) { Text($0.label).tag($0.id) }
                            }
                        }
                        Text("台語：成大台語伺服器無法直接念漢字時，先用上方選的模型轉成台羅再合成（OpenAI 預設 gpt-4.1）；仍失敗才改用音質較差的舊伺服器。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(ConfigStore.fields.filter { visibleKeys.contains($0.key) }) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.displayName).font(.subheadline).foregroundStyle(.secondary)
                            Group {
                                if field.isSecure {
                                    SecureField(field.hint, text: binding(field.key))
                                } else {
                                    TextField(field.hint, text: binding(field.key))
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            if let help = help(field.key) {
                                Text(help).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let validationError {
                    Section { Text(validationError).foregroundStyle(.red) }
                }
            }
            .navigationTitle("ReminiCare AI 設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "儲存中…" : "儲存並套用") { save() }.disabled(saving)
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear(perform: loadValues)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func help(_ key: String) -> String? {
        switch key {
        case ConfigKey.introSilence, ConfigKey.chatSilence: "開始說話後，連續安靜這段時間才自動結束；尚未說話最多等待 15 秒。"
        case ConfigKey.maxRecord: "單次錄音總時限，與說完後等待時間分開計算。"
        default: nil
        }
    }

    private func loadValues() {
        try? config.load()
        values = Dictionary(uniqueKeysWithValues: ConfigStore.fields.map { ($0.key, config.value($0.key)) })
        llm = config.value(ConfigKey.llmProvider)
        image = config.value(ConfigKey.imageProvider)
        speech = config.value(ConfigKey.speechProvider)
        fallback = TaiwaneseTtsFallback.parse(config.value(ConfigKey.taiwaneseFallback))
        taiLoProvider = TaiLoModelSettings.parseProvider(config.value(ConfigKey.taiLoProvider))
    }

    private func save() {
        var updated = values
        updated[ConfigKey.llmProvider] = llm
        updated[ConfigKey.imageProvider] = image
        updated[ConfigKey.speechProvider] = speech
        updated[ConfigKey.taiwaneseFallback] = fallback.rawValue
        updated[ConfigKey.taiLoProvider] = taiLoProvider
        if let error = config.validate(updated) {
            validationError = error
            return
        }
        saving = true
        validationError = nil
        do {
            try config.save(updated)
            dismiss()
        } catch {
            saving = false
            validationError = "設定儲存失敗，原設定已保留，請重試。"
        }
    }
}

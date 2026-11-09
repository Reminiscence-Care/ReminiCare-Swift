import ReminiCareKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let config = ConfigStore.shared
    @State private var values: [String: String] = [:]
    @State private var llm = "nvidia"
    @State private var image = "cloudflare"
    @State private var speech = SpeechProvider.yating.rawValue
    @State private var fallback = TaiwaneseTtsFallback.llmThenLegacy
    @State private var taiLoProvider = TaiLoModelSettings.defaultProvider
    @State private var saving = false
    @State private var validationError: String?
    @State private var health: [ServiceKind: HealthResult] = [:]
    @State private var checking: Set<ServiceKind> = []
    private let history = HealthHistory()

    private var visibleKeys: [String] {
        var keys = [ConfigStore.llmKey(llm), ConfigStore.llmModelKey(llm), ConfigStore.imageKey(image)]
        switch SpeechProvider(speech) {
        case .ncku:
            keys += ["NCKU_TTS_TOKEN", "NCKU_STT_TOKEN"]
            if fallback.usesLlm {
                keys.append(ConfigKey.taiLoModel)
                keys.append(taiLoProvider == TaiLoModelSettings.followCurrent
                    ? ConfigStore.llmKey(llm)
                    : ConfigStore.llmKey(taiLoProvider))
            }
        case .yatingDirect:
            keys.append("YATING_API_KEY")
        case .yating:
            keys += [ConfigKey.speechWorkerToken, ConfigKey.speechWorkerURL]
        }
        keys += [ConfigKey.maxRecord, ConfigKey.introSilence, ConfigKey.chatSilence]
        if llm == "custom" { keys.append("CUSTOM_LLM_BASE_URL") }
        if image == "custom" { keys += ["CUSTOM_IMAGE_BASE_URL", "CUSTOM_IMAGE_MODEL"] }
        if image == "cloudflare" { keys.append("CLOUDFLARE_IMAGE_WORKER_URL") }
        keys.append(ConfigKey.errorReportURL)
        return keys
    }

    private var llmInfo: String {
        switch llm {
        case "nvidia": "https://integrate.api.nvidia.com/v1"
        case "openai": "https://api.openai.com/v1"
        case "gemini": "https://generativelanguage.googleapis.com/v1beta/openai"
        case "groq": "https://api.groq.com/openai/v1"
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
                        Text("Groq").tag("groq")
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
                        ForEach(SpeechProvider.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                    if SpeechProvider(speech) == .yating {
                        Text("語音經 ReminiCare Worker 轉送：只用一般 HTTPS，學校或公司網路擋 WebSocket 時也能辨識；雅婷 Key 放在 Worker，這裡只填 App Token。")
                            .font(.footnote).foregroundStyle(.secondary)
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
                Section("語音辨識文字") {
                    Toggle("用 AI 校正辨識錯字", isOn: toggle(ConfigKey.transcriptCorrection, default: true))
                    Text("依照當下的問題修正同音、近音錯字（例如「字過，不」→「織過布」），不增刪內容。會多花幾秒，使用上方的語言模型與 Key；失敗時沿用原文。自我介紹的稱呼不會自動改字。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("生圖前確認辨識文字", isOn: toggle(ConfigKey.transcriptConfirmation, default: false))
                    Text("開啟後，每次回答與修圖要求都會先顯示「我聽到的是…」，按「對，繼續」才產生照片，也可以修改文字或重新錄音。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let validationError {
                    Section { Text(validationError).foregroundStyle(.red) }
                }
                Section {
                    ForEach(ServiceKind.allCases, id: \.self) { kind in
                        healthRow(kind)
                    }
                } header: {
                    HStack {
                        Text("服務狀態")
                        Spacer()
                        Button("全部檢查") { checkAll() }
                            .font(.subheadline)
                            .disabled(!checking.isEmpty)
                    }
                } footer: {
                    Text("用上方目前填的值測試（不必先儲存）。只送最小的請求：不會產生圖片，語言模型約用十幾個字的額度。")
                }
                Section("診斷") {
                    NavigationLink {
                        RecordingTestView()
                    } label: {
                        Label("錄音測試", systemImage: "waveform.badge.mic")
                    }
                    NavigationLink {
                        NetworkCheckView()
                    } label: {
                        Label("網路檢測", systemImage: "network")
                    }
                    UpdateRow()
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

    /// A "true"/"false" setting as a switch; an empty value means `default`.
    private func toggle(_ key: String, default on: Bool) -> Binding<Bool> {
        Binding(
            get: { (values[key] ?? "").isEmpty ? on : values[key] == "true" },
            set: { values[key] = $0 ? "true" : "false" }
        )
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

    /// The form as it stands, saved or not.
    private var formValues: [String: String] {
        var updated = values
        updated[ConfigKey.llmProvider] = llm
        updated[ConfigKey.imageProvider] = image
        updated[ConfigKey.speechProvider] = speech
        updated[ConfigKey.taiwaneseFallback] = fallback.rawValue
        updated[ConfigKey.taiLoProvider] = taiLoProvider
        return updated
    }

    private var checker: ServiceHealthChecker {
        ServiceHealthChecker(config: ConfigStore(values: formValues.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
    }

    @ViewBuilder
    private func healthRow(_ kind: ServiceKind) -> some View {
        let provider = checker.providerName(kind)
        let result = health[kind].flatMap { $0.provider == provider ? $0 : nil } ?? history.latest(kind, provider: provider)
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color(result?.status))
                .frame(width: 12, height: 12)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(kind.label)：\(provider)").font(.subheadline)
                if checking.contains(kind) {
                    Text("檢查中…").font(.caption).foregroundStyle(.secondary)
                } else if let result {
                    let code = result.statusCode.map { "（HTTP \($0)）" } ?? ""
                    Text("\(result.status.label)\(code)・\(result.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(result.status.isUsable ? Color.secondary : Color.red)
                    if !result.status.isUsable || result.status == .unverifiable {
                        Text(result.status.advice).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("尚未檢查").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if checking.contains(kind) {
                ProgressView()
            } else {
                Button("測試") { check(kind) }.buttonStyle(.borderless)
            }
        }
    }

    private func color(_ status: HealthStatus?) -> Color {
        switch status {
        case nil: .gray
        case .ok?: .green
        case .unverifiable?, .slow?, .rateLimited?: .orange
        default: .red
        }
    }

    private func check(_ kind: ServiceKind) {
        let checker = checker
        checking.insert(kind)
        Task {
            let result = await checker.check(kind)
            history.save(result)
            health[kind] = result
            checking.remove(kind)
        }
    }

    private func checkAll() {
        for kind in ServiceKind.allCases where !checking.contains(kind) { check(kind) }
    }

    private func save() {
        let updated = formValues
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

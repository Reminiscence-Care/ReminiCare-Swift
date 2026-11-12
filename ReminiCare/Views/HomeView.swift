import ReminiCareKit
import SwiftUI

struct HomeView: View {
    @Binding var path: [Route]
    @State private var ready = false
    @State private var loadError: String?
    @State private var showSettings = false
    @State private var missingMessage: String?
    @State private var checkingNetwork = false
    @State private var networkWarning: String?
    @State private var showNetworkCheck = false
    @State private var update: UpdateInfo?
    @Environment(\.openURL) private var openURL
    private let updatePreferences = UpdatePreferences()

    private static let homeImage = BundledImage.home.flatMap { UIImage(contentsOfFile: $0.path) } ?? UIImage()

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 16)
                Image(uiImage: Self.homeImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 560, maxHeight: min(max(geometry.size.height * 0.62, 120), 360))
                    .clipShape(RoundedRectangle(cornerRadius: 31))
                Text("一起聊聊以前的生活")
                    .font(.system(size: geometry.size.width < 600 ? 32 : 44))
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                Spacer(minLength: 16)
                PillButton(
                    label: checkingNetwork ? "檢查網路中…" : (ready ? "開始回憶" : (loadError ?? "載入設定中…")),
                    disabled: checkingNetwork || (!ready && loadError == nil)
                ) {
                    if ready { start() } else { load() }
                }
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .navigationTitle("ReminiCare AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { path.append(.ttsCache) } label: { Image(systemName: "waveform.badge.minus") }
                    .accessibilityLabel("語音快取")
                Button { path.append(.history) } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("回憶紀錄")
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("設定")
            }
        }
        .logToolbar()
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("還不能開始", isPresented: Binding(get: { missingMessage != nil }, set: { if !$0 { missingMessage = nil } })) {
            Button("設定") { showSettings = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text(missingMessage ?? "")
        }
        .alert("網路可能有問題", isPresented: Binding(get: { networkWarning != nil }, set: { if !$0 { networkWarning = nil } })) {
            Button("仍要開始") { path.append(.life) }
            Button("網路檢測") { showNetworkCheck = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text(networkWarning ?? "")
        }
        .alert(
            "有新版本 \(update?.version ?? "")",
            isPresented: Binding(get: { update != nil }, set: { if !$0 { update = nil } }),
            presenting: update
        ) { info in
            Button("更新") { install(info) }
            Button("略過這版") { updatePreferences.skip(info.version) }
            Button("稍後", role: .cancel) {}
        } message: { info in
            Text(updateMessage(info))
        }
        .sheet(isPresented: $showNetworkCheck) {
            NavigationStack {
                NetworkCheckView()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { showNetworkCheck = false } } }
            }
        }
        .task { load() }
        .task { await offerUpdate() }
    }

    /// On launch, at most once a day and only in release builds.
    private func offerUpdate() async {
        guard UpdateChecker.isReleaseBuild, updatePreferences.shouldCheck() else { return }
        let result = await UpdateChecker().check()
        if result != .failed { updatePreferences.markChecked() }
        update = updatePreferences.launchOffer(result)
    }

    private func updateMessage(_ info: UpdateInfo) -> String {
        let how = "按「更新」會開啟 AltStore 安裝新版，回憶與設定都會保留。"
        let notes = info.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? how : String(notes.prefix(300)) + "\n\n" + how
    }

    private func install(_ info: UpdateInfo) {
        guard let altStore = info.altStoreURL else {
            AppLog.shared.record(.update, .progress, detail: "updateOpenPage")
            openURL(info.pageURL)
            return
        }
        AppLog.shared.record(.update, .progress, detail: "updateOpenAltStore")
        let openURL = openURL
        let page = info.pageURL
        openURL(altStore) { accepted in
            guard !accepted else { return }
            AppLog.shared.record(.update, .progress, detail: "updateOpenPage")
            Task { @MainActor in openURL(page) }
        }
    }

    private func load() {
        loadError = nil
        do {
            try ConfigStore.shared.load()
            ready = true
            Task { await KeyWorker.refresh() }
        } catch {
            loadError = "設定讀取失敗，點此重試"
        }
    }

    private func start() {
        #if DEBUG
        // Simulator UI checks without real keys; never in release builds.
        if ProcessInfo.processInfo.arguments.contains("-skipConfigCheck") {
            path.append(.life)
            return
        }
        #endif
        if let message = ServiceFactory().missingConfiguration() {
            missingMessage = message
            return
        }
        // A quick look at the network first: warn, never block.
        checkingNetwork = true
        Task {
            let check = NetworkCheck.quick()
            await check.run()
            checkingNetwork = false
            let failed = check.failedItems
            if failed.isEmpty {
                path.append(.life)
            } else {
                let names = failed.map(\.title).joined(separator: "、")
                networkWarning = "目前連不到：\(names)。對話中可能無法辨識或產生圖片。建議改用手機熱點，或按「網路檢測」查看原因。"
            }
        }
    }
}

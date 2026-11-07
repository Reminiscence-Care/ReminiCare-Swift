import ReminiCareKit
import SwiftUI

struct HomeView: View {
    @Binding var path: [Route]
    @State private var ready = false
    @State private var loadError: String?
    @State private var showSettings = false
    @State private var missingMessage: String?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 16)
                Image("HomeImage")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 560, maxHeight: min(max(geometry.size.height * 0.62, 120), 360))
                    .clipShape(RoundedRectangle(cornerRadius: 31))
                Text("一起聊聊以前的生活")
                    .font(.system(size: geometry.size.width < 600 ? 32 : 44))
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                Spacer(minLength: 16)
                PillButton(label: ready ? "開始回憶" : (loadError ?? "載入設定中…"), disabled: !ready && loadError == nil) {
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
        .task { load() }
    }

    private func load() {
        loadError = nil
        do {
            try ConfigStore.shared.load()
            ready = true
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
        } else {
            path.append(.life)
        }
    }
}

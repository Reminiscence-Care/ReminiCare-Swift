import ReminiCareKit
import SwiftUI

/// Settings → 診斷 → 檢查更新: works in every build, unlike the launch check.
struct UpdateRow: View {
    @Environment(\.openURL) private var openURL
    @State private var checking = false
    @State private var result: UpdateCheckResult?
    private let current = ReportEnvironment.current

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("檢查更新", systemImage: "arrow.down.app")
                Spacer()
                if checking {
                    ProgressView()
                } else {
                    Button("檢查") { check() }.buttonStyle(.borderless)
                }
            }
            Text("目前版本 \(current.appVersion)\(current.appCommit.map { "（\($0)）" } ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            switch result {
            case .available(let info)?:
                Text("有新版本 \(info.version)").font(.subheadline)
                Button("用 AltStore 安裝", systemImage: "square.and.arrow.down") { install(info) }
                    .buttonStyle(.borderless)
            case .upToDate(let latest)?:
                Text("已是最新版本（最新發佈：\(latest)）").font(.caption).foregroundStyle(.secondary)
            case .failed?:
                Text("檢查失敗，請確認網路後再試。").font(.caption).foregroundStyle(.red)
            case nil:
                EmptyView()
            }
        }
    }

    private func check() {
        checking = true
        Task {
            result = await UpdateChecker().check()
            checking = false
        }
    }

    private func install(_ info: UpdateInfo) {
        guard let altStore = info.altStoreURL else {
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
}

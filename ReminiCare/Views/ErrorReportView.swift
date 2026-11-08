import ReminiCareKit
import SwiftUI

/// Sends the App Log, a settings summary (no keys) and the user's own words
/// to the development team. The log is captured when this screen opens.
struct ErrorReportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [AppLogEntry] = []
    @State private var description = ""
    @State private var includeTranscripts = true
    @State private var sending = false
    @State private var pending = 0
    @State private var result: ResultMessage?
    private let service = ErrorReportService.live()

    struct ResultMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let closes: Bool
    }

    private var preview: ErrorReport {
        ErrorReportBuilder.make(
            description: description, includeTranscripts: includeTranscripts, entries: entries, config: .shared
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $description)
                        .font(.system(size: 20))
                        .frame(minHeight: 140)
                        .overlay(alignment: .topLeading) {
                            if description.isEmpty {
                                Text("例如：回答「我沒有織過布」，畫面顯示成別的字")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("發生了什麼事？").font(.system(size: 18))
                } footer: {
                    Text("簡單寫下剛才在做什麼、看到什麼就好，也可以不寫。").font(.system(size: 16))
                }
                Section {
                    Toggle("附上語音辨識文字", isOn: $includeTranscripts).font(.system(size: 20))
                    Text("執行紀錄裡有長輩說的話被辨識出的文字，附上才能判斷辨識或校正的問題。關掉的話只送出其他紀錄。")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("App 版本", value: "\(preview.appVersion)（\(preview.appBuild)）" + (preview.appCommit.map { "・\($0)" } ?? ""))
                    LabeledContent("裝置", value: preview.deviceModel)
                    LabeledContent("執行紀錄", value: "\(entries.count) 筆")
                    LabeledContent("設定摘要", value: "服務與模型名稱；Key 只標示是否已設定")
                    DisclosureGroup("預覽送出的紀錄") {
                        ScrollView {
                            Text(preview.log.isEmpty ? "（沒有紀錄）" : preview.log)
                                .font(.system(size: 14, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 320)
                    }
                } header: {
                    Text("會送出的內容").font(.system(size: 18))
                } footer: {
                    Text("只傳給開發團隊，不會傳送任何 API Key、Token 或錄音檔。").font(.system(size: 16))
                }
                if pending > 0 {
                    Section {
                        HStack {
                            Text("還有 \(pending) 筆回報沒送出").font(.system(size: 18))
                            Spacer()
                            Button("重送") { Task { await resend() } }.disabled(sending)
                        }
                    }
                }
            }
            .navigationTitle("回報問題")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "送出中…" : "送出") { Task { await send() } }.disabled(sending)
                }
            }
            .alert(item: $result) { result in
                Alert(
                    title: Text(result.title), message: Text(result.message),
                    dismissButton: .default(Text("好")) { if result.closes { dismiss() } }
                )
            }
        }
        .interactiveDismissDisabled(sending)
        .onAppear { entries = AppLog.shared.entries }
        .task {
            pending = await service.pendingCount()
            if pending > 0 { await resend(quietly: true) }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        switch await service.submit(preview) {
        case .sent(let issue):
            result = ResultMessage(title: "已送出", message: "謝謝！回報編號 #\(issue)，告訴開發團隊這個編號就能找到。", closes: true)
        case .saved(let error):
            result = ResultMessage(title: "已先保存", message: error.message, closes: true)
        case .failed(let error):
            result = ResultMessage(title: "沒有送出", message: error.message, closes: false)
        }
        pending = await service.pendingCount()
    }

    private func resend(quietly: Bool = false) async {
        sending = true
        defer { sending = false }
        let issues = await service.resendPending()
        pending = await service.pendingCount()
        if !quietly || !issues.isEmpty {
            let numbers = issues.map { "#\($0)" }.joined(separator: "、")
            result = ResultMessage(
                title: issues.isEmpty ? "還是送不出去" : "已補送",
                message: issues.isEmpty ? "請確認網路後再試。" : "先前的回報已送出：\(numbers)",
                closes: false
            )
        }
    }
}

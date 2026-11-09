import ReminiCareKit
import SwiftUI
import UIKit

/// Settings → 網路檢測: can this network reach every service the app uses?
struct NetworkCheckView: View {
    @State private var check = NetworkCheck()
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text("檢查目前的網路能不能連到 App 用到的每個服務，每項試 \(NetworkCheck.attempts) 次。包含語音辨識實際使用、但學校或公司防火牆常擋的 WebSocket 連線。不會送出錄音或對話內容，結果會記在執行紀錄裡。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    copied = false
                    Task { await check.run() }
                } label: {
                    HStack {
                        Label(check.items.isEmpty ? "開始檢測" : "重新檢測", systemImage: "network")
                        if check.running {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(check.running)
                if let environment = check.environment {
                    LabeledContent("目前網路", value: environment.label)
                }
            }

            if !check.items.isEmpty {
                Section("結果") {
                    ForEach(check.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Circle()
                                .fill(color(item.status))
                                .frame(width: 12, height: 12)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.title)：\(item.status.label)").font(.subheadline)
                                if !item.summary.isEmpty {
                                    Text(item.summary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !check.running {
                    Section {
                        Button(copied ? "已複製" : "複製檢測結果", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = check.reportText
                            copied = true
                        }
                    } footer: {
                        Text("連不上或時好時壞時：先試試改用手機熱點再檢測一次。熱點正常、這個 Wi-Fi 不正常，就是這個網路擋住了，請網管開放上面列出的網址；也可以到執行紀錄按「回報問題」把結果送給開發團隊。")
                    }
                }
            }
        }
        .navigationTitle("網路檢測")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func color(_ status: NetworkCheckItem.Status) -> Color {
        switch status {
        case .ok: .green
        case .slow, .partial, .warning: .orange
        case .failed: .red
        case .skipped: .gray
        }
    }
}

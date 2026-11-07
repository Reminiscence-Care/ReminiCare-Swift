import ReminiCareKit
import SwiftUI

struct AppLogView: View {
    @ObservedObject private var log = AppLog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let entries = Array(log.entries.reversed())
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Text("本次執行 \(Int(log.elapsed)) 秒・\(entries.count)/\(log.capacity) 筆・最新在上方").font(.system(size: 20))
                    Button("複製", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = log.exportText()
                        copied = true
                    }
                    .disabled(entries.isEmpty)
                    Button("清除", systemImage: "trash") { log.clear() }.disabled(entries.isEmpty)
                }
                Text("包含語音辨識文字；複製紀錄也會包含文字。重新啟動後清空。").font(.system(size: 17))
                Divider()
                if entries.isEmpty {
                    Text("尚無執行紀錄").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(entries) { entry in
                        Text(entry.line)
                            .font(.system(size: 18, design: .monospaced))
                            .foregroundStyle(entry.isError ? Color.red : Color.primary)
                            .textSelection(.enabled)
                    }
                    .listStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationTitle("執行紀錄")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.backward") }.accessibilityLabel("返回")
            }
        }
        .alert("已複製紀錄", isPresented: $copied) { Button("好", role: .cancel) {} }
    }
}

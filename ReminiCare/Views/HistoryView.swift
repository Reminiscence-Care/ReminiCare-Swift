import ReminiCareKit
import SwiftUI

struct HistoryView: View {
    private let repository = MemoryRepository()
    @State private var records: [MemoryRecord] = []
    @State private var loading = true
    @State private var error: String?
    @State private var pendingDelete: MemoryRecord?

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(.orange)
            } else if let error {
                Button(error) { Task { await load() } }
            } else if records.isEmpty {
                Text("目前還沒有回憶紀錄喔！\n快去跟長輩們聊聊天吧～")
                    .font(.system(size: 18)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                List {
                    ForEach(records) { record in
                        NavigationLink {
                            MemoryDetailView(record: record, imageURL: repository.imageURL(record.imagePath))
                        } label: {
                            RecordRow(record: record, imageURL: repository.imageURL(record.imagePath))
                        }
                        .swipeActions {
                            Button("刪除", systemImage: "trash", role: .destructive) { pendingDelete = record }
                        }
                        .contextMenu {
                            Button("刪除", systemImage: "trash", role: .destructive) { pendingDelete = record }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("回憶紀錄")
        .logToolbar()
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("刪除回憶", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { record in
            Button("取消", role: .cancel) {}
            Button("確定刪除", role: .destructive) { Task { await delete(record) } }
        } message: { _ in
            Text("確定要刪除這筆回憶紀錄嗎？\n刪除後將無法復原喔！")
        }
    }

    private func load() async {
        do {
            records = try await repository.load()
            error = nil
        } catch {
            AppLog.shared.record(.history, .failed, detail: "load")
            self.error = "無法讀取回憶，請重試。"
        }
        loading = false
    }

    private func delete(_ record: MemoryRecord) async {
        do {
            try await repository.delete(record.id)
            await load()
        } catch {
            AppLog.shared.record(.history, .failed, detail: "delete")
            self.error = "刪除失敗，請重試。"
        }
    }
}

private struct RecordRow: View {
    let record: MemoryRecord
    let imageURL: URL?
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            MemoryImage(url: imageURL, cornerRadius: 12).frame(width: 120)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(record.topic).font(.system(size: 18, weight: .bold)).lineLimit(1)
                    Spacer()
                    Text(record.date).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                }
                Text("參與者：\(record.elders)").font(.system(size: 14, weight: .semibold)).foregroundStyle(.blue.opacity(0.7)).lineLimit(1)
                Text(record.content).font(.system(size: 14)).lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }
}

struct MemoryDetailView: View {
    let record: MemoryRecord
    let imageURL: URL?

    var body: some View {
        GeometryReader { geometry in
            let size = min(max(geometry.size.width * 0.06, 24), 40)
            ScrollView {
                VStack(spacing: size * 2) {
                    VStack(spacing: size * 0.2) {
                        Text("回憶詳細資料").font(.system(size: size * 1.1, weight: .bold))
                        Text(record.date).font(.system(size: size * 0.7, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, size * 0.8)
                    .frame(maxWidth: 600)
                    .background(Color(red: 1, green: 0.976, blue: 0.9), in: Capsule())
                    let info = VStack(alignment: .leading, spacing: size * 0.6) {
                        row("主題", record.topic, size)
                        row("內容", record.content, size)
                        row("分享者", record.elders, size)
                    }
                    if geometry.size.width >= 800 {
                        HStack(alignment: .top, spacing: size * 2) {
                            info.frame(maxWidth: .infinity)
                            MemoryImage(url: imageURL, cornerRadius: 16).frame(maxWidth: geometry.size.width * 0.32)
                        }
                    } else {
                        info
                        MemoryImage(url: imageURL, cornerRadius: 16)
                    }
                }
                .padding(.vertical, size * 2)
                .padding(.horizontal, size * 2.5)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(size)
                .frame(maxWidth: 1200)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(.systemGray5))
    }

    private func row(_ label: String, _ value: String, _ size: CGFloat) -> some View {
        HStack(alignment: .top, spacing: size * 1.2) {
            Text("\(label)：")
                .font(.system(size: size * 0.85, weight: .bold))
                .frame(width: size * 4.2)
                .padding(.vertical, size * 0.4)
                .background(Color(red: 1, green: 0.976, blue: 0.9), in: RoundedRectangle(cornerRadius: size))
            Text(value).font(.system(size: size * 0.95)).lineSpacing(6).padding(.top, size * 0.25)
            Spacer(minLength: 0)
        }
    }
}

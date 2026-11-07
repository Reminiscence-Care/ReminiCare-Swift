import AVFoundation
import ReminiCareKit
import SwiftUI

struct TtsCacheView: View {
    private let cache = TtsCache()
    @State private var entries: [TtsCacheEntry] = []
    @State private var player: AVAudioPlayer?
    @State private var playingKey: String?
    @State private var regenerating: Set<String> = []
    @State private var confirmClear = false
    @State private var message: String?

    var body: some View {
        List {
            if entries.isEmpty {
                Text("目前沒有語音快取").foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                HStack(spacing: 12) {
                    Text(entry.language.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.paleYellow, in: Capsule())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).font(.system(size: 17)).lineLimit(2)
                        Text("\(entry.size / 1024) KB・\(entry.lastUsed.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await toggle(entry) } } label: {
                        Image(systemName: playingKey == entry.key ? "stop.circle.fill" : "play.circle.fill").font(.system(size: 30))
                    }
                    .buttonStyle(.borderless)
                    Button { Task { await regenerate(entry) } } label: {
                        if regenerating.contains(entry.key) { ProgressView() } else { Image(systemName: "arrow.clockwise").font(.system(size: 22)) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(regenerating.contains(entry.key))
                }
                .swipeActions {
                    Button("刪除", systemImage: "trash", role: .destructive) {
                        Task {
                            await cache.remove(entry.key)
                            message = "已刪除該筆語音快取"
                            await reload()
                        }
                    }
                }
            }
        }
        .navigationTitle("語音快取")
        .logToolbar()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("全部清除", systemImage: "trash") { confirmClear = true }.disabled(entries.isEmpty)
            }
        }
        .task { await reload() }
        .onDisappear { player?.stop() }
        .alert("全部清除", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task {
                    player?.stop()
                    await cache.clear()
                    message = "所有語音快取已清除完畢！"
                    await reload()
                }
            }
        } message: {
            Text("確定要清除所有已下載的語音檔嗎？\n清除後若需再次播放將重新消耗網路流量。")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        }
    }

    private func reload() async { entries = await cache.entries() }

    private func toggle(_ entry: TtsCacheEntry) async {
        player?.stop()
        if playingKey == entry.key {
            playingKey = nil
            return
        }
        let url = await cache.url(for: entry)
        guard let next = try? AVAudioPlayer(contentsOf: url) else {
            AppLog.shared.record(.cache, .failed, detail: "playback")
            message = "播放失敗，檔案可能已損毀"
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = next
        playingKey = entry.key
        next.play()
        try? await Task.sleep(for: .seconds(next.duration))
        if playingKey == entry.key { playingKey = nil }
    }

    private func regenerate(_ entry: TtsCacheEntry) async {
        regenerating.insert(entry.key)
        try? ConfigStore.shared.load()
        let ok = await cache.regenerate(entry, synthesizer: ServiceFactory().synthesizer())
        regenerating.remove(entry.key)
        if !ok { AppLog.shared.record(.cache, .failed, detail: "save") }
        message = ok ? "重新生成成功！" : "重新生成失敗，請檢查網路"
        await reload()
    }
}

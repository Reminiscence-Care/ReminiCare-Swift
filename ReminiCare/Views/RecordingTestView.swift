import ReminiCareKit
import SwiftUI
import UIKit

/// Settings → 錄音測試: checks the microphone with the conversation's own recorder.
struct RecordingTestView: View {
    @State private var test = RecordingTest()
    @State private var copied = false
    @State private var appleLines: [AppleSpeechDiagnostics.Line] = []
    @State private var diagnosing = false

    var body: some View {
        Form {
            Section {
                Text("用和對話相同的方式錄一段話（最多 30 秒），檢查麥克風有沒有收到聲音、錄音格式是否正確，再播放或送到目前設定的語音服務辨識。")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button {
                        Task { test.phase == .recording ? await test.stop() : await test.start() }
                    } label: {
                        Label(test.phase == .recording ? "停止錄音" : "開始錄音",
                              systemImage: test.phase == .recording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title3)
                    }
                    .disabled(![.idle, .ready, .recording].contains(test.phase))
                    if test.phase == .recording {
                        Text("\(test.recordSeconds) 秒").monospacedDigit().foregroundStyle(.secondary)
                    } else if test.phase == .analyzing {
                        ProgressView()
                        Text("分析錄音中…").foregroundStyle(.secondary)
                    }
                }
                if test.phase == .recording {
                    LevelBar(db: test.level)
                }
                if let error = test.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                Text("錄音")
            }

            if let result = test.result {
                Section("錄音結果") {
                    if let route = result.route {
                        LabeledContent("輸入裝置", value: route.input.label)
                        LabeledContent("硬體取樣率", value: "\(route.sampleRate) Hz")
                    }
                    if let inspection = result.inspection {
                        if inspection.exists {
                            LabeledContent("格式", value: inspection.formatDescription)
                            LabeledContent("長度", value: String(format: "%.1f 秒（%d bytes）", inspection.seconds, inspection.fileBytes))
                            if let peak = inspection.peakDb, let rms = inspection.rmsDb {
                                LabeledContent("音量", value: "峰值 \(Int(peak.rounded())) dB，平均 \(Int(rms.rounded())) dB")
                            }
                            if let loud = inspection.loudPercent, let zero = inspection.zeroPercent {
                                LabeledContent("有聲／全零", value: "\(loud)% ／ \(zero)%")
                            }
                        }
                        Label(inspection.verdict.advice,
                              systemImage: inspection.verdict == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(inspection.verdict == .ok ? .green : .orange)
                    }
                }

                Section("播放與辨識") {
                    if test.phase == .playing {
                        Button("停止播放", systemImage: "stop.fill") { test.stopPlaying() }
                    } else {
                        Button("播放錄音", systemImage: "play.fill") { Task { await test.play() } }
                            .disabled(!test.canPlay)
                    }
                    Text("播放的是未經調整的原始錄音，音量比 App 念題目小是正常的。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("送到語音辨識", systemImage: "text.bubble") { Task { await test.transcribe() } }
                        .disabled(!test.canTranscribe)
                    if test.phase == .transcribing {
                        HStack { ProgressView(); Text("辨識中…").foregroundStyle(.secondary) }
                    }
                    if let transcript = test.transcript, !transcript.isEmpty {
                        Text(transcript)
                    }
                    if let message = test.sttMessage {
                        Text(message).foregroundStyle(.orange)
                    }
                }

                Section {
                    Button(diagnosing ? "診斷中…" : "Apple 辨識診斷", systemImage: "stethoscope") {
                        guard let file = test.file else { return }
                        diagnosing = true
                        appleLines = []
                        Task {
                            appleLines = await AppleSpeechDiagnostics.run(file)
                            diagnosing = false
                        }
                    }
                    .disabled(diagnosing || !test.canTranscribe)
                    ForEach(appleLines) { line in
                        LabeledContent(line.method) { Text(line.outcome).textSelection(.enabled) }
                    }
                } footer: {
                    Text("用這段錄音試 Apple 每一種辨識方式，找出這台 iPad 可用的那一種。「送 Apple 伺服器」那一項會把錄音傳給 Apple；新框架缺模型時會先下載。")
                }

                Section {
                    Button(copied ? "已複製" : "複製診斷結果", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = test.reportText
                        copied = true
                    }
                    if let file = test.file {
                        ShareLink(item: file) { Label("分享錄音檔", systemImage: "square.and.arrow.up") }
                    }
                } footer: {
                    Text("診斷結果只有數字與辨識文字；錄音檔只有你按「分享」時才會離開這台 iPad，離開本頁就會刪除。")
                }
            }
        }
        .navigationTitle("錄音測試")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: test.result?.file) { copied = false }
        .onDisappear { Task { await test.close() } }
    }
}

/// Meter level from −60 dBFS (empty) to 0 dBFS (full).
private struct LevelBar: View {
    let db: Double

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(max((db + 60) / 60, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(fraction > 0.85 ? Color.red : Color.green)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 10)
        .animation(.linear(duration: 0.15), value: db)
        .accessibilityLabel("音量 \(Int(db)) dB")
    }
}

import Foundation
import Observation

/// Settings-page microphone check: records with exactly the recorder, audio
/// session and file location the conversation uses, then reports what the file
/// contains, plays it back and can send it to the configured speech recognizer.
@MainActor
@Observable
public final class RecordingTest {
    public enum Phase: Sendable, Equatable { case idle, recording, analyzing, ready, playing, transcribing }

    public static let maximum: Duration = .seconds(30)

    public private(set) var phase: Phase = .idle
    /// Latest meter reading in dBFS while recording.
    public private(set) var level: Double = -160
    public private(set) var recordSeconds = 0
    public private(set) var result: RecordingResult?
    public private(set) var errorMessage: String?
    public private(set) var transcript: String?
    public private(set) var sttMessage: String?
    public private(set) var sttDurationMs: Int?

    @ObservationIgnored private let controller: RecordingController
    @ObservationIgnored private let playback: PlaybackPort
    @ObservationIgnored private let activate: () throws -> Void
    @ObservationIgnored private let recognizer: () -> SpeechRecognizer
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var operation = 0

    public init(
        recorder: RecorderPort? = nil,
        playback: PlaybackPort? = nil,
        activate: (() throws -> Void)? = nil,
        describeInput: (() -> AudioRouteSnapshot?)? = { AudioRouteSnapshot.current() },
        createURL: (() -> URL)? = nil,
        recognizer: @escaping () -> SpeechRecognizer = { ServiceFactory().recognizer() }
    ) {
        let activate = activate ?? { try VoiceAssistant.activateSession() }
        self.activate = activate
        self.playback = playback ?? NativePlayback()
        self.recognizer = recognizer
        controller = RecordingController(
            port: recorder ?? NativeRecorder(),
            createURL: createURL ?? { VoiceAssistant.recordingURL() },
            activate: activate,
            describeInput: describeInput
        )
        controller.onLevel = { [weak self] in self?.level = $0 }
        controller.onState = { [weak self] state in
            if state == .stopping { self?.phase = .analyzing }
        }
        controller.onCompleted = { [weak self] in self?.finish($0) }
    }

    public var file: URL? { result?.file }
    public var canPlay: Bool { phase == .ready && file != nil }
    public var canTranscribe: Bool { phase == .ready && result?.inspection.map { $0.verdict != .fileMissing && $0.verdict != .notWav } == true }

    public func start() async {
        guard phase == .idle || phase == .ready else { return }
        discardFile()
        result = nil
        errorMessage = nil
        transcript = nil
        sttMessage = nil
        sttDurationMs = nil
        level = -160
        recordSeconds = 0
        operation += 1
        AppLog.shared.record(.recording, .started, operationId: operation, detail: "recordingTest")
        do {
            // No pause detection beyond the recorder's own 15 s idle stop: the
            // user presses stop, so quiet speech is still captured.
            guard try await controller.start(silenceTimeout: Self.maximum, maximumDuration: Self.maximum) else { return }
        } catch {
            errorMessage = (error as? SttError)?.message ?? "無法啟動麥克風，請重試。"
            phase = .idle
            return
        }
        phase = .recording
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.phase == .recording else { return }
                self.recordSeconds += 1
            }
        }
    }

    public func stop() async {
        guard phase == .recording else { return }
        await controller.stop(.manual)
    }

    private func finish(_ result: RecordingResult) {
        timer?.cancel()
        self.result = result
        phase = .ready
    }

    public func play() async {
        guard canPlay, let file else { return }
        do { try activate() } catch {
            errorMessage = "無法取得音訊使用權，請稍後再試。"
            return
        }
        phase = .playing
        let outcome = await playback.play(file)
        if phase == .playing { phase = .ready }
        if outcome == .failed { errorMessage = "錄音檔無法播放。" }
    }

    public func stopPlaying() {
        playback.stop()
        if phase == .playing { phase = .ready }
    }

    /// Sends the recording to the saved speech service, logging like the conversation does.
    public func transcribe() async {
        guard canTranscribe, let file else { return }
        phase = .transcribing
        transcript = nil
        sttMessage = nil
        let watch = Stopwatch()
        AppLog.shared.record(.stt, .started, operationId: operation, detail: "recordingTest")
        do {
            let text = try await recognizer().transcribe(file, progress: nil)
            sttDurationMs = watch.milliseconds
            AppLog.shared.record(.stt, .completed, operationId: operation, durationMs: watch.milliseconds, detail: "recordingTest")
            AppLog.shared.recordTranscription(text, operationId: operation)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            transcript = trimmed
            if trimmed.isEmpty {
                AppLog.shared.record(.stt, .warning, operationId: operation, detail: "emptyTranscript")
                sttMessage = "語音服務正常回應，但沒有辨識出任何文字。請對照上方錄音結果：若音量正常，問題在語音辨識端。"
            }
        } catch {
            sttDurationMs = watch.milliseconds
            let stt = error as? SttError
            AppLog.shared.record(.stt, .failed, operationId: operation, durationMs: watch.milliseconds, detail: stt?.kind.rawValue ?? logDetail(error))
            sttMessage = stt?.message ?? "語音辨識失敗。"
        }
        if phase == .transcribing { phase = .ready }
    }

    /// Stops everything and deletes the test recording.
    public func close() async {
        timer?.cancel()
        playback.stop()
        await controller.stop(.cancelled)
        discardFile()
        result = nil
        phase = .idle
    }

    private func discardFile() {
        if let file = result?.file { try? FileManager.default.removeItem(at: file) }
    }

    /// Plain-text summary for "copy diagnostics"; numbers and codes only, plus the STT text.
    public var reportText: String {
        var lines = ["ReminiCare 錄音測試", "系統：\(ProcessInfo.processInfo.operatingSystemVersionString)"]
        if let route = result?.route {
            var input = "輸入裝置：\(route.input.label)，硬體取樣率 \(route.sampleRate) Hz，輸入聲道 \(route.inputChannels)"
            if let gain = route.inputGainPercent { input += "，輸入增益 \(gain)%" }
            if !route.inputAvailable { input += "（系統回報沒有可用的麥克風）" }
            lines.append(input)
        }
        if let result {
            lines.append("停止原因：\(AppLog.detailLabels[result.reason.rawValue] ?? result.reason.rawValue)，錄音 \(String(format: "%.1f", result.duration.seconds)) 秒")
        }
        if let inspection = result?.inspection {
            lines += Self.describe(inspection)
        }
        if let sttDurationMs {
            if let transcript, !transcript.isEmpty {
                lines.append("語音辨識（\(sttDurationMs) ms）：\(transcript)")
            } else {
                lines.append("語音辨識（\(sttDurationMs) ms）：\(sttMessage ?? "沒有文字")")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func describe(_ inspection: WavInspection) -> [String] {
        guard inspection.exists else { return ["結果：\(inspection.verdict.advice)"] }
        var lines = [
            "格式：\(inspection.formatDescription)",
            "檔案：\(inspection.fileBytes) bytes，音訊 \(String(format: "%.1f", inspection.seconds)) 秒",
        ]
        if let peak = inspection.peakDb, let rms = inspection.rmsDb {
            lines.append("音量：峰值 \(Int(peak.rounded())) dB，平均 \(Int(rms.rounded())) dB")
        }
        if let loud = inspection.loudPercent, let zero = inspection.zeroPercent, let clip = inspection.clipPercent {
            lines.append("有聲 \(loud)%，全零 \(zero)%，爆音 \(clip)%")
        }
        lines.append("結果：\(inspection.verdict.advice)")
        return lines
    }
}

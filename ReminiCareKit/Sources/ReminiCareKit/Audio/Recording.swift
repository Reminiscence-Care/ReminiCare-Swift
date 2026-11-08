import AVFoundation
import Foundation

/// Receives elapsed time since recording began; avoids timer tick drift.
public struct SpeechPauseDetector: Sendable {
    public let silenceTimeout: Duration
    public let idleTimeout: Duration
    public private(set) var hasSpoken = false
    private var loudSamples = 0
    private var lastVoice: Duration = .zero

    public init(silenceTimeout: Duration, idleTimeout: Duration = .seconds(15)) {
        self.silenceTimeout = silenceTimeout
        self.idleTimeout = idleTimeout
    }

    /// True when recording should stop.
    public mutating func sample(elapsed: Duration, loud: Bool) -> Bool {
        if loud {
            loudSamples += 1
            if loudSamples >= 2 { hasSpoken = true }
            if hasSpoken { lastVoice = elapsed }
            return false
        }
        loudSamples = 0
        return hasSpoken ? elapsed - lastVoice >= silenceTimeout : elapsed >= idleTimeout
    }
}

@MainActor
public protocol RecorderPort: AnyObject {
    func hasPermission() async -> Bool
    func start(_ url: URL) throws
    /// Stops and returns the file, or nil if nothing was written.
    func stop() -> URL?
    /// Current input level in dBFS (−160…0), nil when unavailable.
    func powerDb() -> Double?
    /// Called when the system ends recording on its own.
    var onUnexpectedStop: (() -> Void)? { get set }
}

/// 16 kHz mono 16-bit PCM WAV via AVAudioRecorder with metering.
@MainActor
public final class NativeRecorder: NSObject, RecorderPort, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var stopping = false
    public var onUnexpectedStop: (() -> Void)?

    public override init() {}

    public func hasPermission() async -> Bool {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    public func start(_ url: URL) throws {
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        guard recorder.record() else { throw SttError(.invalidAudio, "目前無法取得麥克風或音訊使用權，請稍後重試。") }
        stopping = false
        self.recorder = recorder
    }

    public func stop() -> URL? {
        guard let recorder else { return nil }
        stopping = true
        recorder.stop()
        self.recorder = nil
        return recorder.url
    }

    public func powerDb() -> Double? {
        guard let recorder, recorder.isRecording else { return nil }
        recorder.updateMeters()
        return Double(recorder.averagePower(forChannel: 0))
    }

    public nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !self.stopping { self.onUnexpectedStop?() }
        }
    }

    public nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.onUnexpectedStop?() }
    }
}

public enum RecordingState: String, Sendable { case idle, preparing, recording, stopping, completed, failed }
public enum RecordingStopReason: String, Sendable { case manual, silence, idle, maximumDuration, interrupted, cancelled }

public struct RecordingResult: Sendable {
    public let file: URL?
    public let reason: RecordingStopReason
    public let duration: Duration
    /// What the file contains; nil for cancelled recordings.
    public var inspection: WavInspection?
    /// Input in use when recording started; nil where unknown.
    public var route: AudioRouteSnapshot?
}

@MainActor
public final class RecordingController {
    public let port: RecorderPort
    public let createURL: () -> URL
    public let activate: () throws -> Void
    public var sampleInterval: Duration
    /// Extra recording after a manual stop so the last word is not cut off.
    public var manualStopTail: Duration
    public private(set) var state: RecordingState = .idle
    public var onState: ((RecordingState) -> Void)?
    public var onWarning: ((String) -> Void)?
    public var onCompleted: ((RecordingResult) -> Void)?
    /// Each meter reading in dBFS while recording (for a level bar).
    public var onLevel: ((Double) -> Void)?
    /// Describes the input in use; logged once recording starts. Codes only.
    public var describeInput: (() -> AudioRouteSnapshot?)?

    private var epoch = 0
    private var file: URL?
    private var started = ContinuousClock.now
    private var sampler: Task<Void, Never>?
    private var stopping: Task<RecordingResult?, Never>?
    private var peakDb: Double?
    private var route: AudioRouteSnapshot?

    public init(
        port: RecorderPort,
        createURL: @escaping () -> URL,
        activate: @escaping () throws -> Void,
        sampleInterval: Duration = .milliseconds(200),
        manualStopTail: Duration = .milliseconds(800),
        describeInput: (() -> AudioRouteSnapshot?)? = nil
    ) {
        self.port = port
        self.createURL = createURL
        self.activate = activate
        self.sampleInterval = sampleInterval
        self.manualStopTail = manualStopTail
        self.describeInput = describeInput
        port.onUnexpectedStop = { [weak self] in
            guard let self, self.state == .recording else { return }
            AppLog.shared.record(.recording, .warning, operationId: self.epoch, detail: "unexpectedStop")
            Task { await self.stop(.interrupted) }
        }
    }

    private func setState(_ value: RecordingState) {
        AppLog.shared.record(.recording, value == .failed ? .failed : .stageChanged, operationId: epoch, detail: value.rawValue)
        state = value
        onState?(value)
    }

    public func start(silenceTimeout: Duration, maximumDuration: Duration) async throws -> Bool {
        guard [.idle, .completed, .failed].contains(state) else { return false }
        epoch += 1
        let current = epoch
        setState(.preparing)
        do {
            guard await port.hasPermission() else {
                AppLog.shared.record(.recording, .failed, operationId: epoch, detail: "permissionDenied")
                throw SttError(.invalidAudio, "麥克風權限未開啟，請到裝置設定允許錄音。")
            }
            guard current == epoch else { return false }
            do { try activate() } catch {
                AppLog.shared.record(.recording, .failed, operationId: epoch, detail: "audioSession")
                throw SttError(.invalidAudio, "目前無法取得麥克風或音訊使用權，請稍後重試。")
            }
            let url = createURL()
            do { try port.start(url) } catch {
                AppLog.shared.record(.recording, .failed, operationId: epoch, detail: "recorderStart")
                throw error
            }
            guard current == epoch else { return false }
            file = url
            started = .now
            peakDb = nil
            setState(.recording)
            logInput(epoch: current)
            sampler = Task { [weak self] in await self?.sample(epoch: current, silenceTimeout: silenceTimeout, maximum: maximumDuration) }
            return true
        } catch {
            if current == epoch { setState(.failed) }
            _ = port.stop()
            throw error
        }
    }

    private func logInput(epoch current: Int) {
        route = describeInput?()
        guard let route else { return }
        AppLog.shared.record(
            .recording, .progress, operationId: current,
            sampleRate: route.sampleRate, channels: route.inputChannels, detail: route.input.rawValue
        )
        if !route.inputAvailable {
            AppLog.shared.record(.recording, .warning, operationId: current, detail: "inputUnavailable")
        }
    }

    private func sample(epoch current: Int, silenceTimeout: Duration, maximum: Duration) async {
        var threshold = -35.0
        var calibrated = false
        var noise: [Double] = []
        var failures = 0
        var pause = SpeechPauseDetector(silenceTimeout: silenceTimeout)
        while !Task.isCancelled, current == epoch, state == .recording {
            try? await Task.sleep(for: sampleInterval)
            guard current == epoch, state == .recording else { return }
            let elapsed = ContinuousClock.now - started
            if elapsed >= maximum {
                Task { await self.stop(.maximumDuration) }
                return
            }
            guard failures < 3 else { continue }
            guard let db = port.powerDb(), db.isFinite else {
                failures += 1
                if failures >= 3 {
                    AppLog.shared.record(.recording, .warning, operationId: current, detail: "amplitudeUnavailable")
                    onWarning?("自動停頓偵測暫時無法使用，請說完後按「說完了」。")
                }
                continue
            }
            failures = 0
            peakDb = max(peakDb ?? db, db)
            onLevel?(db)
            // Speech counts immediately; only quiet samples calibrate the noise floor.
            if !calibrated {
                if db > -100 && db < -35 { noise.append(db) }
                if elapsed >= .seconds(1) {
                    if noise.count >= 3 {
                        noise.sort()
                        threshold = min(max(noise[noise.count / 4] + 10, -45), -35)
                    }
                    calibrated = true
                }
            }
            if pause.sample(elapsed: elapsed, loud: db >= threshold) {
                let reason: RecordingStopReason = pause.hasSpoken ? .silence : .idle
                Task { await self.stop(reason) }
                return
            }
        }
    }

    @discardableResult
    public func stop(_ reason: RecordingStopReason) async -> RecordingResult? {
        if state == .stopping { return await stopping?.value }
        guard state == .recording || state == .preparing else { return nil }
        epoch += 1
        sampler?.cancel()
        setState(.stopping)
        let tail = manualStopTail
        let task = Task<RecordingResult?, Never> { @MainActor in
            if reason == .manual && tail > .zero { try? await Task.sleep(for: tail) }
            let duration = ContinuousClock.now - started
            var url = port.stop() ?? file
            file = nil
            if let path = url?.path, !FileManager.default.fileExists(atPath: path) { url = nil }
            var result = RecordingResult(file: url, reason: reason, duration: duration, route: route)
            if reason == .cancelled {
                AppLog.shared.record(
                    .recording, .recordingStopped, operationId: epoch,
                    durationMs: Int(duration.seconds * 1000), detail: reason.rawValue
                )
            } else {
                // Measured from the file itself: catches silence the meter cannot
                // (all-zero samples) and format problems the STT would reject.
                let file = url
                let inspection = await Task.detached { WavInspection.inspect(file: file) }.value
                result.inspection = inspection
                AppLog.shared.record(
                    .recording, .recordingStopped, operationId: epoch,
                    durationMs: Int(duration.seconds * 1000), bytes: inspection.exists ? inspection.fileBytes : nil,
                    peakDb: (inspection.peakDb ?? peakDb).map { Int($0.rounded()) },
                    avgDb: inspection.rmsDb.map { Int($0.rounded()) },
                    loudPercent: inspection.loudPercent, zeroPercent: inspection.zeroPercent,
                    sampleRate: inspection.sampleRate, channels: inspection.channels, detail: reason.rawValue
                )
                if inspection.verdict != .ok {
                    AppLog.shared.record(.recording, .warning, operationId: epoch, detail: inspection.verdict.rawValue)
                }
            }
            setState(.completed)
            if reason == .cancelled {
                if let url { try? FileManager.default.removeItem(at: url) }
            } else {
                onCompleted?(result)
            }
            return result
        }
        stopping = task
        let result = await task.value
        stopping = nil
        return result
    }
}

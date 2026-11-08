import AVFoundation
import Foundation

public enum PlaybackOutcome: Sendable { case completed, cancelled, failed }

@MainActor
public protocol PlaybackPort: AnyObject {
    func play(_ url: URL) async -> PlaybackOutcome
    func stop()
}

@MainActor
public final class NativePlayback: NSObject, PlaybackPort, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<PlaybackOutcome, Never>?

    public override init() {}

    public func play(_ url: URL) async -> PlaybackOutcome {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            AppLog.shared.record(.tts, .failed, detail: "playback")
            return .failed
        }
        player.delegate = self
        self.player = player
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if !player.play() {
                AppLog.shared.record(.tts, .failed, detail: "playStartFailed")
                finish(.failed)
            }
        }
    }

    public func stop() {
        player?.stop()
        player = nil
        finish(.cancelled)
    }

    private func finish(_ outcome: PlaybackOutcome) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: outcome)
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerEnded(id, flag ? .completed : .failed) }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            AppLog.shared.record(.tts, .failed, detail: "playerError")
            self.playerEnded(id, .failed)
        }
    }

    private func playerEnded(_ id: ObjectIdentifier, _ outcome: PlaybackOutcome) {
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        finish(outcome)
    }
}

/// Microphone and speaker as seen by the conversation flow.
@MainActor
public protocol VoiceIO: AnyObject {
    var onPlayingLanguageChanged: ((SpeechLanguage) -> Void)? { get set }
    var onSpeechCompleted: (([URL]) -> Void)? { get set }
    var onInterrupted: (([URL]) -> Void)? { get set }
    var onWarning: ((String) -> Void)? { get set }
    var onRecordingFailed: (() -> Void)? { get set }
    var isRecording: Bool { get }
    func play(_ texts: [String], languages: [SpeechLanguage]) async -> PlaybackOutcome
    func stopPlayback()
    func startRecording(silence: Duration, maximum: Duration) async throws -> Bool
    func finishRecording() async
    func cancelRecording() async
    func interrupt() async
    func close() async
}

/// Owns one recorder and one player; every microphone/playback request goes through here.
@MainActor
public final class VoiceAssistant: VoiceIO {
    public var onPlayingLanguageChanged: ((SpeechLanguage) -> Void)?
    public var onSpeechCompleted: (([URL]) -> Void)?
    public var onInterrupted: (([URL]) -> Void)?
    public var onWarning: ((String) -> Void)?
    public var onRecordingFailed: (() -> Void)?

    private let recording: RecordingController
    private let playback: PlaybackPort
    private let cache: TtsCache
    private let synthesizer: SpeechSynthesizer
    private let identity: String
    private var playToken = 0
    private var observers: [NSObjectProtocol] = []
    private var closed = false

    public init(
        synthesizer: SpeechSynthesizer,
        identity: String,
        cache: TtsCache = TtsCache(),
        recorder: RecorderPort? = nil,
        playback: PlaybackPort? = nil,
        activate: (() throws -> Void)? = nil
    ) {
        self.synthesizer = synthesizer
        self.identity = identity
        self.cache = cache
        self.playback = playback ?? NativePlayback()
        // Real input is described only with the real recorder (not in tests).
        let describeInput: (() -> AudioRouteSnapshot?)? = recorder == nil ? { AudioRouteSnapshot.current() } : nil
        recording = RecordingController(
            port: recorder ?? NativeRecorder(),
            createURL: { VoiceAssistant.recordingURL() },
            activate: activate ?? { try VoiceAssistant.activateSession() },
            describeInput: describeInput
        )
        recording.onWarning = { [weak self] in self?.onWarning?($0) }
        recording.onState = { [weak self] state in
            if state == .failed { self?.onRecordingFailed?() }
        }
        recording.onCompleted = { [weak self] result in
            guard let self, !self.closed else { return }
            let files = result.file.map { [$0] } ?? []
            if result.reason == .interrupted { self.onInterrupted?(files) } else { self.onSpeechCompleted?(files) }
        }
        observeSession()
    }

    public var isRecording: Bool { recording.state == .recording }

    /// Temporary WAV for one recording; stale ones are cleaned by `LifeSession`.
    public nonisolated static func recordingURL() -> URL {
        let micros = Int(Date().timeIntervalSince1970 * 1_000_000)
        return FileManager.default.temporaryDirectory.appending(path: "reminicare_chat_smart_\(micros).wav")
    }

    /// The audio session every recording and playback uses.
    public nonisolated static func activateSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #endif
    }

    private func observeSession() {
        #if os(iOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .began else { return }
            AppLog.shared.record(.recording, .warning, detail: "interruptionBegan")
            Task { @MainActor in await self?.interrupt() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let input = AudioRouteSnapshot.current()?.input.rawValue
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                // Any input change mid-recording is logged with the new input,
                // so a switch to a Bluetooth headset shows up next to the result.
                AppLog.shared.record(.recording, .warning, detail: "inputDeviceChanged")
                if let input { AppLog.shared.record(.recording, .progress, detail: input) }
                if reason == .oldDeviceUnavailable {
                    AppLog.shared.record(.recording, .warning, detail: "routeChanged")
                    await self.interrupt()
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            AppLog.shared.record(.recording, .warning, detail: "mediaServicesReset")
            Task { @MainActor in
                if self?.isRecording == true { await self?.interrupt() }
            }
        })
        #endif
    }

    public func play(_ texts: [String], languages: [SpeechLanguage]) async -> PlaybackOutcome {
        guard !closed, recording.state != .recording, recording.state != .preparing else { return .cancelled }
        stopPlayback()
        playToken += 1
        let token = playToken
        func cancelled() -> Bool { closed || token != playToken }
        do { try Self.activateSession() } catch {
            AppLog.shared.record(.tts, .failed, detail: "audioSession")
            return .failed
        }
        for language in languages {
            for text in texts {
                if cancelled() { return .cancelled }
                AppLog.shared.record(.tts, .started, detail: language.logCode)
                let url = await cache.resolve(text, language: language, identity: identity, synthesizer: synthesizer)
                if cancelled() { return .cancelled }
                guard let url else {
                    AppLog.shared.record(.tts, .failed)
                    return .failed
                }
                onPlayingLanguageChanged?(language)
                let watch = Stopwatch()
                let outcome = await playback.play(url)
                AppLog.shared.record(
                    .tts, outcome == .completed ? .completed : outcome == .cancelled ? .cancelled : .failed,
                    durationMs: watch.milliseconds, detail: language.logCode
                )
                if outcome != .completed { return outcome }
                try? await Task.sleep(for: .milliseconds(150))
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return cancelled() ? .cancelled : .completed
    }

    public func stopPlayback() {
        playToken += 1
        playback.stop()
    }

    public func startRecording(silence: Duration, maximum: Duration) async throws -> Bool {
        guard !closed, !isRecording else { return false }
        stopPlayback()
        return try await recording.start(silenceTimeout: silence, maximumDuration: maximum)
    }

    public func finishRecording() async { await recording.stop(.manual) }
    public func cancelRecording() async { await recording.stop(.cancelled) }

    public func interrupt() async {
        stopPlayback()
        await recording.stop(.interrupted)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        stopPlayback()
        await recording.stop(.cancelled)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

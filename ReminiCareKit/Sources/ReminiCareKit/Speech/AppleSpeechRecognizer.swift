import Foundation
// Speech's classes are not marked Sendable; each request and recognizer is used by one task only.
@preconcurrency import Speech

/// Mandarin (zh-TW) recognition with Apple's on-device model, the one keyboard
/// dictation uses offline. No network, no quota, and the audio never leaves
/// the iPad. Never falls back to Apple's servers. Taiwanese is not supported.
public struct AppleSpeechRecognizer: SpeechRecognizer {
    public static let locale = Locale(identifier: "zh-TW")
    public var timeout: Duration = .seconds(120)

    public init() {}

    /// This iPad has the offline zh-TW model (checked without asking for permission).
    public static var isAvailableOffline: Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    public func transcribe(_ file: URL, progress: SttProgress?) async throws -> String {
        guard await Self.authorize() == .authorized else {
            AppLog.shared.record(.stt, .failed, detail: "appleSpeechDenied")
            throw SttError(.authentication, "請到 iPad「設定 → ReminiCare」允許語音辨識，或改用其他語音服務。")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Self.locale), recognizer.supportsOnDeviceRecognition else {
            AppLog.shared.record(.stt, .failed, detail: "appleSpeechUnavailable")
            throw SttError(.authentication, "這台 iPad 沒有繁體中文離線語音模型，請改用其他語音服務。")
        }
        // Read the file ourselves and hand Apple audio buffers: with SFSpeechURLRecognitionRequest the
        // first iPad test (report 5) came back empty in 0.3 s for 6-second recordings with normal volume.
        let buffer: AVAudioPCMBuffer
        do {
            let audio = try AVAudioFile(forReading: file)
            guard let read = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else {
                throw SttError(.invalidAudio, "")
            }
            try audio.read(into: read)
            buffer = read
        } catch {
            AppLog.shared.record(.stt, .failed, detail: "invalidAudio")
            throw SttError(.invalidAudio, "錄音格式不正確或音檔不完整。")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()
        progress?(0, 1)
        let watch = Stopwatch()
        AppLog.shared.record(.stt, .started, bytes: Int(buffer.frameLength) * 2, detail: "appleSpeech")
        do {
            let text = try await withTimeout(timeout) { try await Self.recognize(request, with: recognizer) }
            AppLog.shared.record(.stt, .requestCompleted, durationMs: watch.milliseconds, detail: "appleSpeech")
            progress?(1, 1)
            return text
        } catch is TimeoutError {
            AppLog.shared.record(.stt, .requestFailed, durationMs: watch.milliseconds, detail: "timeout")
            throw SttError(.timeout, "語音辨識逾時，請重試。")
        } catch let error as SttError {
            AppLog.shared.record(.stt, error.kind == .cancelled ? .cancelled : .requestFailed, durationMs: watch.milliseconds, detail: error.kind.rawValue)
            throw error
        }
    }

    /// The final transcript; "" when no speech was detected.
    static func recognize(_ request: SFSpeechRecognitionRequest, with recognizer: SFSpeechRecognizer) async throws -> String {
        let task = LockedValue<SFSpeechRecognitionTask?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let resumed = LockedValue(false)
                func finish(_ result: Result<String, Error>) {
                    guard resumed.withValue({ done in defer { done = true }; return !done }) else { return }
                    continuation.resume(with: result)
                }
                let started = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        let text = result.bestTranscription.formattedString
                        if text.isEmpty { AppLog.shared.record(.stt, .warning, detail: "appleSpeechEmptyResult") }
                        return finish(.success(text))
                    }
                    guard let error else { return }
                    finish(Self.outcome(error as NSError))
                }
                task.withValue { $0 = started }
            }
        } onCancel: {
            task.current?.cancel()
        }
    }

    static func outcome(_ error: NSError) -> Result<String, Error> {
        // The code says why Apple gave up; the domain is one of a few fixed names.
        let domain = ["kAFAssistantErrorDomain": "Assistant", "kLSRErrorDomain": "LSR", "SFSpeechErrorDomain": "Speech"][error.domain] ?? "Other"
        AppLog.shared.record(.stt, .warning, statusCode: error.code, detail: "appleSpeechError\(domain)")
        // kAFAssistantErrorDomain 1110 / 203: nothing recognizable was said; an empty transcript lets the session ask again.
        if error.domain == "kAFAssistantErrorDomain" && [1110, 203].contains(error.code) { return .success("") }
        if error.domain == "kAFAssistantErrorDomain" && [216, 301].contains(error.code) {
            return .failure(SttError(.cancelled, "已取消辨識。"))
        }
        return .failure(SttError(.server, "Apple 語音辨識失敗，請重試或改用其他語音服務。"))
    }
}

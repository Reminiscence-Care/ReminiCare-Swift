import Foundation
// Speech's classes are not marked Sendable; each module and analyzer is used by one task only.
@preconcurrency import Speech

/// Mandarin (zh-TW) recognition on the iPad with iPadOS 26's SpeechAnalyzer +
/// SpeechTranscriber: no quota, and the audio is not sent anywhere.
/// The legacy SFSpeechRecognizer claimed on-device support on the test iPad but
/// returned empty results (reports 5–6; diagnostic 2026-11-11), so it is not used.
/// Taiwanese is not supported.
public struct AppleSpeechRecognizer: SpeechRecognizer {
    public static let locale = Locale(identifier: "zh-TW")
    public var timeout: Duration = .seconds(120)

    public init() {}

    /// Running iPadOS 26 or later, which this recognizer needs.
    public static var isSupportedOS: Bool {
        if #available(iOS 26, macOS 26, *) { true } else { false }
    }

    /// iPadOS 26 and a zh-TW SpeechTranscriber (the model downloads on first use).
    public static func isAvailable() async -> Bool {
        guard #available(iOS 26, macOS 26, *) else { return false }
        return await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    public func transcribe(_ file: URL, progress: SttProgress?) async throws -> String {
        guard #available(iOS 26, macOS 26, *), await Self.isAvailable() else {
            AppLog.shared.record(.stt, .failed, detail: "appleSpeechUnavailable")
            throw SttError(.authentication, "Apple 離線辨識需要 iPadOS 26 以上，請改用其他語音服務。")
        }
        guard await Self.authorize() == .authorized else {
            AppLog.shared.record(.stt, .failed, detail: "appleSpeechDenied")
            throw SttError(.authentication, "請到 iPad「設定 → ReminiCare」允許語音辨識，或改用其他語音服務。")
        }
        progress?(0, 1)
        let watch = Stopwatch()
        AppLog.shared.record(.stt, .started, detail: "appleSpeech")
        do {
            let text = try await withTimeout(timeout) { try await Self.transcribeOnDevice(file) }
            AppLog.shared.record(.stt, .requestCompleted, durationMs: watch.milliseconds, detail: "appleSpeech")
            if text.isEmpty { AppLog.shared.record(.stt, .warning, detail: "appleSpeechEmptyResult") }
            progress?(1, 1)
            return text
        } catch is TimeoutError {
            AppLog.shared.record(.stt, .requestFailed, durationMs: watch.milliseconds, detail: "timeout")
            throw SttError(.timeout, "語音辨識逾時，請重試。")
        } catch where isCancellation(error) {
            throw SttError(.cancelled, "已取消辨識。")
        } catch {
            let ns = error as NSError
            AppLog.shared.record(.stt, .requestFailed, durationMs: watch.milliseconds, statusCode: ns.code, detail: "appleSpeechErrorOther")
            throw SttError(.server, "Apple 語音辨識失敗，請重試或改用其他語音服務。")
        }
    }

    @available(iOS 26, macOS 26, *)
    static func transcribeOnDevice(_ file: URL) async throws -> String {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        return try await analyze(file, module: module) {
            var text = ""
            for try await result in module.results where result.isFinal { text += String(result.text.characters) }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs one recorded file through `module`; `results` collects its output.
    @available(iOS 26, macOS 26, *)
    static func analyze(
        _ file: URL, module: any SpeechModule, results: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        // Downloads the model when it is missing (needs network once).
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            AppLog.shared.record(.stt, .progress, detail: "appleSpeechModelDownload")
            try await install.downloadAndInstall()
        }
        let audio = try AVAudioFile(forReading: file)
        let analyzer = SpeechAnalyzer(modules: [module])
        async let text = results()
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await text
    }
}

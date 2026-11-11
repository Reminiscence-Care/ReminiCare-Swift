import Foundation
@preconcurrency import Speech

/// Settings → 錄音測試 → Apple 辨識診斷: runs one recording through every way the
/// app can reach Apple's recognizer, to find which one works on this iPad.
/// Reports 5–6 showed the legacy on-device path returning an empty final
/// result in 0.3 s with no error, while keyboard dictation worked offline.
public enum AppleSpeechDiagnostics {
    public struct Line: Sendable, Identifiable {
        public let id = UUID()
        public let method: String
        public let outcome: String
    }

    public static func run(_ file: URL) async -> [Line] {
        guard await AppleSpeechRecognizer.authorize() == .authorized else {
            return [Line(method: "權限", outcome: "未允許語音辨識")]
        }
        var lines: [Line] = []
        let locale = AppleSpeechRecognizer.locale
        if let recognizer = SFSpeechRecognizer(locale: locale) {
            lines.append(Line(method: "舊框架狀態",
                              outcome: "可用=\(recognizer.isAvailable)  支援離線=\(recognizer.supportsOnDeviceRecognition)"))
            lines.append(await legacy("舊框架・離線・分段餵入", file, recognizer, onDevice: true))
            lines.append(await legacy("舊框架・送 Apple 伺服器", file, recognizer, onDevice: false))
        } else {
            lines.append(Line(method: "舊框架狀態", outcome: "不支援 zh-TW"))
        }
        if #available(iOS 26, macOS 26, *) {
            lines += await analyzer(file, locale: locale)
        } else {
            lines.append(Line(method: "新框架", outcome: "需要 iPadOS 26"))
        }
        return lines
    }

    private static func timed(_ method: String, _ body: @escaping @Sendable () async throws -> String) async -> Line {
        let watch = Stopwatch()
        do {
            let text = try await withTimeout(.seconds(60)) { try await body() }
            let seconds = String(format: "%.1f", Double(watch.milliseconds) / 1000)
            return Line(method: method, outcome: text.isEmpty ? "沒有文字（\(seconds) 秒）" : "「\(text)」（\(seconds) 秒）")
        } catch is TimeoutError {
            return Line(method: method, outcome: "逾時")
        } catch {
            let ns = error as NSError
            return Line(method: method, outcome: "錯誤 \(ns.domain) \(ns.code)：\(ns.localizedDescription)")
        }
    }

    private static func legacy(_ method: String, _ file: URL, _ recognizer: SFSpeechRecognizer, onDevice: Bool) async -> Line {
        await timed(method) {
            let audio = try AVAudioFile(forReading: file)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = onDevice
            request.shouldReportPartialResults = false
            request.addsPunctuation = true
            // 0.1-second buffers, the size a live microphone tap delivers.
            let chunk = AVAudioFrameCount(audio.processingFormat.sampleRate / 10)
            while audio.framePosition < audio.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: chunk) else { break }
                try audio.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
                request.append(buffer)
            }
            request.endAudio()
            return try await rawRecognize(request, with: recognizer)
        }
    }

    /// Legacy recognition; errors are passed through untouched so the code is visible.
    private static func rawRecognize(_ request: SFSpeechRecognitionRequest, with recognizer: SFSpeechRecognizer) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let resumed = LockedValue(false)
            recognizer.recognitionTask(with: request) { result, error in
                let outcome: Result<String, Error>?
                if let result, result.isFinal { outcome = .success(result.bestTranscription.formattedString) }
                else if let error { outcome = .failure(error) }
                else { outcome = nil }
                guard let outcome, resumed.withValue({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: outcome)
            }
        }
    }

    @available(iOS 26, macOS 26, *)
    private static func analyzer(_ file: URL, locale: Locale) async -> [Line] {
        var lines: [Line] = []
        let wanted = locale.identifier(.bcp47)
        let speechLocales = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        let dictationLocales = await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        let chinese = (speechLocales + dictationLocales).filter { $0.hasPrefix("zh") || $0.hasPrefix("yue") }
        lines.append(Line(method: "新框架支援的中文", outcome: Set(chinese).sorted().joined(separator: "、").isEmpty
            ? "沒有" : Set(chinese).sorted().joined(separator: "、")))
        if speechLocales.contains(wanted) {
            lines.append(await timed("新框架・SpeechTranscriber") {
                let module = SpeechTranscriber(locale: locale, preset: .transcription)
                return try await AppleSpeechRecognizer.analyze(file, module: module) {
                    var text = ""
                    for try await result in module.results where result.isFinal { text += String(result.text.characters) }
                    return text
                }
            })
        } else {
            lines.append(Line(method: "新框架・SpeechTranscriber", outcome: "不支援 \(wanted)"))
        }
        if dictationLocales.contains(wanted) {
            lines.append(await timed("新框架・DictationTranscriber") {
                let module = DictationTranscriber(locale: locale, preset: .shortDictation)
                return try await AppleSpeechRecognizer.analyze(file, module: module) {
                    var text = ""
                    for try await result in module.results where result.isFinal { text += String(result.text.characters) }
                    return text
                }
            })
        } else {
            lines.append(Line(method: "新框架・DictationTranscriber", outcome: "不支援 \(wanted)"))
        }
        return lines
    }
}

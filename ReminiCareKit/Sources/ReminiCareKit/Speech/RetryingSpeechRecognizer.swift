import Foundation

/// Sends the same recording once more when recognition fails for a reason a
/// second try can fix (a dropped connection, a timeout, a server hiccup) or
/// comes back empty, so the speaker does not have to repeat the answer.
public struct RetryingSpeechRecognizer: SpeechRecognizer {
    public let base: SpeechRecognizer
    public var delay: Duration = .seconds(1)

    public init(_ base: SpeechRecognizer, delay: Duration = .seconds(1)) {
        self.base = base
        self.delay = delay
    }

    /// Worth a second try: transport and server trouble. Not wrong keys, bad
    /// audio, oversized recordings or a cancel, which would fail the same way.
    /// An incomplete result that already has text is kept for the caller instead.
    static func isRetryable(_ error: SttError) -> Bool {
        switch error.kind {
        case .network, .timeout, .server: true
        case .incomplete: error.partialText.isEmpty
        default: false
        }
    }

    public func transcribe(_ file: URL, progress: SttProgress?) async throws -> String {
        do {
            let text = try await base.transcribe(file, progress: progress)
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
            AppLog.shared.record(.stt, .warning, detail: "sttRetryEmpty")
        } catch let error as SttError where Self.isRetryable(error) {
            AppLog.shared.record(.stt, .warning, detail: "sttRetry")
        }
        do { try await Task.sleep(for: delay) } catch { throw SttError(.cancelled, "已取消辨識。") }
        let text = try await base.transcribe(file, progress: progress)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AppLog.shared.record(.stt, .completed, detail: "sttRetrySucceeded")
        }
        return text
    }
}

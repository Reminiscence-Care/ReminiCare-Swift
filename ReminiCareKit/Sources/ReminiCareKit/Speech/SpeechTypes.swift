import Foundation

public enum SttErrorKind: String, Sendable {
    case payloadTooLarge, authentication, invalidAudio, network, timeout, server, invalidResponse, cancelled, incomplete
}

public struct SttError: Error, Sendable, LocalizedError {
    public let kind: SttErrorKind
    public let message: String
    public var partialText = ""
    public init(_ kind: SttErrorKind, _ message: String, partialText: String = "") {
        self.kind = kind
        self.message = message
        self.partialText = partialText
    }
    public var errorDescription: String? { message }
}

public typealias SttProgress = @Sendable (_ complete: Int, _ total: Int) -> Void

public protocol SpeechRecognizer: Sendable {
    /// Transcribes a 16 kHz mono WAV file. Cancelling the task aborts recognition.
    func transcribe(_ file: URL, progress: SttProgress?) async throws -> String
}

public protocol SpeechSynthesizer: Sendable {
    /// WAV audio, or nil when synthesis failed (failures are logged).
    func synthesize(_ text: String, language: SpeechLanguage) async -> Data?
}

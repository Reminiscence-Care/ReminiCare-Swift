import Foundation
@testable import ReminiCareKit

struct FakeLlm: LlmClient {
    var reply: @Sendable ([LlmMessage]) throws -> String
    init(_ reply: @escaping @Sendable ([LlmMessage]) throws -> String) { self.reply = reply }
    init(_ fixed: String) { reply = { _ in fixed } }
    func complete(messages: [LlmMessage], temperature: Double, maxTokens: Int, jsonObject: Bool) async throws -> String {
        try reply(messages)
    }
}

final class FakeRecognizer: SpeechRecognizer, @unchecked Sendable {
    let results = LockedValue<[Result<String, Error>]>([])
    let calls = LockedValue(0)
    init(_ texts: [String]) { results.withValue { $0 = texts.map { .success($0) } } }
    func transcribe(_ file: URL, progress: SttProgress?) async throws -> String {
        calls.withValue { $0 += 1 }
        progress?(1, 1)
        let next = results.withValue { $0.isEmpty ? .success("") : $0.removeFirst() }
        return try next.get()
    }
}

struct FakeImage: ImageGenerating {
    let store: LocalImageStore
    var config = ProviderRegistry.imagePresets["cloudflare"]!
    let calls = LockedValue(0)
    func generate(prompt: String) async throws -> URL {
        calls.withValue { $0 += 1 }
        return try store.save(Data([0x89, 0x50, 0x4E, 0x47]), prefix: "generated")
    }
    func edit(image: URL, instruction: String) async throws -> URL {
        calls.withValue { $0 += 1 }
        return try store.save(Data([0x89, 0x50, 0x4E, 0x47]), prefix: "edited")
    }
}

struct CountingSynthesizer: SpeechSynthesizer {
    let calls = LockedValue(0)
    func synthesize(_ text: String, language: SpeechLanguage) async -> Data? {
        calls.withValue { $0 += 1 }
        try? await Task.sleep(for: .milliseconds(20))
        return WavAudio(pcm: Data(count: 3200)).encode()
    }
}

@MainActor
final class FakeVoice: VoiceIO {
    var onPlayingLanguageChanged: ((SpeechLanguage) -> Void)?
    var onSpeechCompleted: (([URL]) -> Void)?
    var onInterrupted: (([URL]) -> Void)?
    var onWarning: ((String) -> Void)?
    var onRecordingFailed: (() -> Void)?
    var isRecording = false
    var played: [String] = []
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func play(_ texts: [String], languages: [SpeechLanguage]) async -> PlaybackOutcome {
        played += texts
        return .completed
    }
    func stopPlayback() {}
    func startRecording(silence: Duration, maximum: Duration) async throws -> Bool {
        isRecording = true
        return true
    }
    /// Simulates the user pressing stop: a recording file is delivered.
    func finishRecording() async {
        isRecording = false
        let file = directory.appending(path: "rec_\(UUID().uuidString).wav")
        try? WavAudio(pcm: Data(count: 3200)).encode().write(to: file)
        onSpeechCompleted?([file])
    }
    func cancelRecording() async { isRecording = false }
    func interrupt() async {}
    func close() async {}
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "reminicare-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

import Foundation
import Testing
@testable import ReminiCareKit

@MainActor
final class FakeRecorderPort: RecorderPort {
    var onUnexpectedStop: (() -> Void)?
    var permission = true
    var stops = 0
    var db: (Int) -> Double = { _ in -60 }
    /// What the "recording" contains.
    var pcm = Data(count: 3200)
    private var samples = 0
    private var url: URL?
    func hasPermission() async -> Bool { permission }
    func start(_ url: URL) throws {
        self.url = url
        try WavAudio(pcm: pcm).encode().write(to: url)
    }
    func stop() -> URL? {
        stops += 1
        return url
    }
    func powerDb() -> Double? {
        samples += 1
        return db(samples)
    }
}

@MainActor
@Suite struct RecordingTests {
    func controller(_ port: FakeRecorderPort, tail: Duration = .zero) throws -> RecordingController {
        let directory = try temporaryDirectory()
        return RecordingController(
            port: port, createURL: { directory.appending(path: "audio.wav") }, activate: {},
            sampleInterval: .milliseconds(5), manualStopTail: tail
        )
    }

    @Test func manualStopKeepsRecordingForTheTailButCancelDoesNot() async throws {
        let port = FakeRecorderPort()
        let control = try controller(port, tail: .milliseconds(150))
        _ = try await control.start(silenceTimeout: .seconds(3), maximumDuration: .seconds(20))
        let clock = ContinuousClock.now
        let stopping = Task { await control.stop(.manual) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(port.stops == 0)
        #expect(control.state == .stopping)
        let result = await stopping.value
        #expect(port.stops == 1)
        #expect(ContinuousClock.now - clock >= .milliseconds(150))
        #expect((result?.duration ?? .zero) >= .milliseconds(150))

        _ = try await control.start(silenceTimeout: .seconds(3), maximumDuration: .seconds(20))
        let cancelClock = ContinuousClock.now
        await control.stop(.cancelled)
        #expect(ContinuousClock.now - cancelClock < .milliseconds(150))
    }

    @Test func speechThenSilenceStopsAutomatically() async throws {
        let port = FakeRecorderPort()
        port.db = { $0 < 4 ? -20 : -60 }
        let control = try controller(port)
        var completed: RecordingResult?
        control.onCompleted = { completed = $0 }
        _ = try await control.start(silenceTimeout: .milliseconds(40), maximumDuration: .seconds(5))
        for _ in 0..<100 where completed == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(completed?.reason == .silence)
    }

    @Test func deniedPermissionFails() async throws {
        let port = FakeRecorderPort()
        port.permission = false
        let control = try controller(port)
        await #expect(throws: SttError.self) {
            try await control.start(silenceTimeout: .seconds(3), maximumDuration: .seconds(20))
        }
        #expect(control.state == .failed)
    }
}

@MainActor
@Suite struct LifeSessionTests {
    func make(names: String, transcripts: [String]) throws -> (LifeSession, FakeVoice, FakeImage) {
        let root = try temporaryDirectory()
        let defaults = UserDefaults(suiteName: "reminicare-tests-\(UUID().uuidString)")!
        let config = ConfigStore(defaults: defaults, secrets: MemorySecretStore())
        try config.load()
        let voice = FakeVoice(directory: root)
        let image = FakeImage(store: LocalImageStore(root: root))
        let llm = FakeLlm { messages in
            let system = messages.first?.content ?? ""
            if system.contains("姓氏") { return names }
            if system.contains("JSON") && messages.last?.content.contains("topicId") == true { throw AIServiceError(.network, "offline") }
            if system.contains("scene") { return #"{"scene":"market","era":"1970s","location":"Tainan","keywords":["市場","阿嬤"]}"# }
            return "還記得是誰帶您去的嗎？"
        }
        let session = LifeSession(
            config: config, ai: ReminiscenceAI(client: llm), image: image,
            recognizer: FakeRecognizer(transcripts), memories: MemoryRepository(root: root), voice: { voice }
        )
        return (session, voice, image)
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func fullConversationSavesAMemory() async throws {
        let (session, voice, image) = try make(names: #"{"surname":"王","title":"先生"}"#, transcripts: ["我叫王小明，叫我王先生", "以前常去菜市場"])
        await session.initialize()
        #expect(session.stage == .topicSelection)
        #expect(session.topics.count == 4)
        #expect(session.topicWarning != nil)
        session.selectTopic(session.topics[0])
        await session.startIntroductionRecording()
        #expect(session.introductionState == .recording)
        await voice.finishRecording()
        try await waitUntil { session.introductionState == .confirmed }
        #expect(session.currentElderName == "王先生")
        await session.finishIntroduction()
        #expect(session.elderNames == ["王先生"])
        #expect(session.stage == .question)
        await session.startAnswerRecording()
        await voice.finishRecording()
        try await waitUntil { session.stage == .evaluation }
        #expect(image.calls.current == 1)
        #expect(session.keywords == ["市場", "阿嬤"])
        #expect(session.currentImageURL != nil)
        await session.chooseLike()
        #expect(session.hasExtension)
        #expect(session.currentQuestion == "還記得是誰帶您去的嗎？")
        await session.finishSession()
        #expect(session.stage == .summary)
        #expect(await session.saveMemory())
    }

    @Test func unconfirmedSurnameShowsWhatWasHeard() async throws {
        let (session, voice, _) = try make(names: "Extract name: ?", transcripts: ["我叫家燕"])
        await session.initialize()
        session.selectTopic(session.topics[0])
        await session.startIntroductionRecording()
        await voice.finishRecording()
        try await waitUntil { session.introductionState == .confirmed }
        #expect(session.currentElderName == "家燕")
        #expect(session.errorMessage == nil)
        session.correctParticipantAddress(ParticipantAddress("吳", "女士"), revision: session.introductionRevision)
        #expect(session.currentElderName == "吳女士")
    }

    @Test func silentRecordingAsksAgain() async throws {
        let (session, voice, _) = try make(names: "{}", transcripts: [""])
        await session.initialize()
        session.selectTopic(session.topics[0])
        await session.startIntroductionRecording()
        await voice.finishRecording()
        try await waitUntil { session.errorMessage != nil }
        #expect(session.errorMessage == LifeSession.emptyTranscriptMessage)
        #expect(session.introductionState == .ready)
        // The recording is kept so it can be sent again.
        #expect(session.canRetryTranscription)
    }
}

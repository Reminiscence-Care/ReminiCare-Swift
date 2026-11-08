import Foundation
import Testing
@testable import ReminiCareKit

// MARK: Helpers

/// Mono 16-bit sine at the given peak level (dBFS).
func sinePCM(db: Double, seconds: Double, sampleRate: Int = 16_000, channels: Int = 1) -> Data {
    let amplitude = 32767 * pow(10, db / 20)
    var data = Data()
    for index in 0..<Int(seconds * Double(sampleRate)) {
        let value = Int16((amplitude * sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))).rounded())
        for _ in 0..<channels {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
    }
    return data
}

/// Canonical WAV with any rate and channel count (WavAudio.wav is mono only).
func wav(_ pcm: Data, sampleRate: Int, channels: Int) -> Data {
    var header = Data()
    func text(_ value: String) { header.append(contentsOf: Array(value.utf8)) }
    func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
    func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { header.append(contentsOf: $0) } }
    text("RIFF"); u32(36 + pcm.count); text("WAVE")
    text("fmt "); u32(16); u16(1); u16(channels)
    u32(sampleRate); u32(sampleRate * channels * 2); u16(channels * 2); u16(16)
    text("data"); u32(pcm.count)
    return header + pcm
}

struct FakeHTTP: HTTPSending {
    let respond: @Sendable (URLRequest) -> (Int, String)
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

/// Answers "ready", then the scripted pipe messages once the client sends EOF.
final class FakeYatingChannel: YatingChannel, @unchecked Sendable {
    private let state = LockedValue<(ready: Bool, eof: Bool, queue: [String])>((false, false, []))
    let afterEOF: [String]
    init(afterEOF: [String]) { self.afterEOF = afterEOF }

    func send(_ data: Data) async throws {
        if data.isEmpty { state.withValue { $0.eof = true; $0.queue = afterEOF } }
    }

    func receive() async throws -> String? {
        if !state.withValue({ $0.ready }) {
            state.withValue { $0.ready = true }
            return #"{"status":"ok"}"#
        }
        while true {
            try Task.checkCancellation()
            if let next = state.withValue({ $0.eof && !$0.queue.isEmpty ? $0.queue.removeFirst() : nil }) { return next }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func close() {}
}

// MARK: WAV inspection

@Suite struct WavInspectionTests {
    @Test func normalSpeechLevelIsOk() {
        let result = WavInspection.inspect(WavAudio(pcm: sinePCM(db: -12, seconds: 1)).encode())
        #expect(result.verdict == .ok)
        #expect(result.sampleRate == 16_000 && result.channels == 1 && result.bitsPerSample == 16)
        #expect(abs((result.peakDb ?? 0) + 12) < 0.5)
        #expect(result.loudPercent == 100)
        #expect(abs(result.seconds - 1) < 0.001)
    }

    @Test func classifiesSilenceAndLowLevels() {
        #expect(WavInspection.inspect(WavAudio(pcm: Data(count: 32_000)).encode()).verdict == .digitalSilence)
        let silent = WavInspection.inspect(WavAudio(pcm: sinePCM(db: -70, seconds: 1)).encode())
        #expect(silent.verdict == .micSilent)
        #expect((silent.zeroPercent ?? 100) < 99)
        #expect(WavInspection.inspect(WavAudio(pcm: sinePCM(db: -50, seconds: 1)).encode()).verdict == .tooQuiet)
        #expect(WavInspection.inspect(WavAudio(pcm: sinePCM(db: -12, seconds: 0.1)).encode()).verdict == .tooShort)
    }

    @Test func reportsFormatMismatchInsteadOfThrowing() {
        let narrow = WavInspection.inspect(wav(sinePCM(db: -12, seconds: 1, sampleRate: 8_000), sampleRate: 8_000, channels: 1))
        #expect(narrow.verdict == .formatMismatch)
        #expect(narrow.sampleRate == 8_000)
        let stereo = WavInspection.inspect(wav(sinePCM(db: -12, seconds: 1, channels: 2), sampleRate: 16_000, channels: 2))
        #expect(stereo.verdict == .formatMismatch)
        #expect(stereo.channels == 2)
        #expect(abs(stereo.seconds - 1) < 0.001)
    }

    @Test func brokenAndMissingFiles() {
        #expect(WavInspection.inspect(Data([1, 2, 3])).verdict == .notWav)
        let truncated = WavAudio(pcm: sinePCM(db: -12, seconds: 1)).encode().dropLast(100)
        let inspection = WavInspection.inspect(Data(truncated))
        #expect(inspection.verdict == .incompleteFile)
        #expect(inspection.dataBytes == 32_000 - 100)
        #expect(WavInspection.inspect(file: URL(fileURLWithPath: "/nonexistent/x.wav")).verdict == .fileMissing)
        #expect(WavInspection.inspect(file: nil).verdict == .fileMissing)
    }

    @Test func extensibleHeaderIsReadAsPcm() throws {
        var fmt = Data()
        func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { fmt.append(contentsOf: $0) } }
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { fmt.append(contentsOf: $0) } }
        le16(0xFFFE); le16(1); le32(16_000); le32(32_000); le16(2); le16(16); le16(22); le16(16); le32(4)
        fmt.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        let pcm = sinePCM(db: -12, seconds: 1)
        var body = Data("WAVE".utf8)
        for (id, payload) in [("fmt ", fmt), ("data", pcm)] {
            body.append(Data(id.utf8))
            withUnsafeBytes(of: UInt32(payload.count).littleEndian) { body.append(contentsOf: $0) }
            body.append(payload)
        }
        var file = Data("RIFF".utf8)
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { file.append(contentsOf: $0) }
        file.append(body)
        let inspection = WavInspection.inspect(file)
        #expect(inspection.formatTag == 0xFFFE)
        #expect(inspection.verdict == .ok)
        #expect(try WavAudio.parse(file).pcm == pcm)
    }
}

// MARK: Recording

@MainActor
@Suite struct RecordingDiagnosticsTests {
    @Test func stopInspectsTheFileAndKeepsTheRoute() async throws {
        let port = FakeRecorderPort()
        port.pcm = Data(count: 32_000 + 2)
        let directory = try temporaryDirectory()
        let route = AudioRouteSnapshot(input: .bluetooth, inputAvailable: true, sampleRate: 16_000, inputChannels: 1, inputGainPercent: 50)
        let control = RecordingController(
            port: port, createURL: { directory.appending(path: "audio.wav") }, activate: {},
            sampleInterval: .milliseconds(5), manualStopTail: .zero, describeInput: { route }
        )
        _ = try await control.start(silenceTimeout: .seconds(3), maximumDuration: .seconds(20))
        let result = try #require(await control.stop(.manual))
        #expect(result.route == route)
        #expect(result.inspection?.verdict == .digitalSilence)
        #expect(result.inspection?.dataBytes == 32_002)
        #expect(AppLog.shared.entries.contains { $0.event == .recordingStopped && $0.bytes == 32_002 + 44 && $0.zeroPercent == 100 })
        #expect(AppLog.shared.entries.contains { $0.detail == "inputBluetooth" })
    }

    @Test func cancelledRecordingIsNotInspected() async throws {
        let port = FakeRecorderPort()
        let directory = try temporaryDirectory()
        let control = RecordingController(port: port, createURL: { directory.appending(path: "audio.wav") }, activate: {})
        _ = try await control.start(silenceTimeout: .seconds(3), maximumDuration: .seconds(20))
        let result = await control.stop(.cancelled)
        #expect(result?.inspection == nil)
    }

    @Test func recordingTestReportsVerdictAndTranscribes() async throws {
        let port = FakeRecorderPort()
        port.pcm = sinePCM(db: -12, seconds: 1)
        let directory = try temporaryDirectory()
        let test = RecordingTest(
            recorder: port, playback: nil, activate: {}, describeInput: { nil },
            createURL: { directory.appending(path: "test.wav") },
            recognizer: { FakeRecognizer([""]) }
        )
        await test.start()
        #expect(test.phase == .recording)
        await test.stop()
        #expect(test.phase == .ready)
        #expect(test.result?.inspection?.verdict == .ok)
        #expect(test.canTranscribe)
        await test.transcribe()
        #expect(test.transcript == "")
        #expect(test.sttMessage != nil)
        #expect(test.reportText.contains("WAV PCM 16000 Hz 單聲道 16-bit"))
        let file = try #require(test.file)
        await test.close()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

// MARK: Speech services

@Suite struct YatingDiagnosticsTests {
    func recognizer(token: @escaping @Sendable (URLRequest) -> (Int, String), afterEOF: [String]) -> YatingSpeechRecognizer {
        var recognizer = YatingSpeechRecognizer(apiKey: { "key" })
        recognizer.http = FakeHTTP(respond: token)
        recognizer.connect = { _ in FakeYatingChannel(afterEOF: afterEOF) }
        recognizer.sendDelay = .zero
        recognizer.completionTimeout = .seconds(2)
        return recognizer
    }

    func file() throws -> URL {
        let url = try temporaryDirectory().appending(path: "speech.wav")
        try WavAudio(pcm: sinePCM(db: -12, seconds: 0.5)).encode().write(to: url)
        return url
    }

    @Test func zeroSentencesIsLoggedAsCompletedWithNoText() async throws {
        let stt = recognizer(token: { _ in (201, #"{"success":true,"auth_token":"t"}"#) }, afterEOF: [#"{"pipe":{"asr_eof":true}}"#])
        let text = try await stt.transcribe(try file(), progress: nil)
        #expect(text == "")
        #expect(AppLog.shared.entries.contains { $0.detail == "yatingEof" && $0.complete == 0 && $0.bytes == 16_000 })
    }

    @Test func countsSentences() async throws {
        let stt = recognizer(token: { _ in (201, #"{"success":true,"auth_token":"t"}"#) }, afterEOF: [
            #"{"pipe":{"asr_sentence":"我姓王","asr_final":true}}"#,
            #"{"pipe":{"asr_eof":true}}"#,
        ])
        #expect(try await stt.transcribe(try file(), progress: nil) == "我姓王")
    }

    @Test func tokenFailuresSayWhy() async throws {
        let cases: [(Int, String, String)] = [
            (402, "{}", "雅婷額度不足或方案已到期，請到雅婷後台確認。"),
            (403, #"{"message":"Quota exceeded"}"#, "雅婷額度不足或方案已到期，請到雅婷後台確認。"),
            (401, #"{"message":"invalid key"}"#, "雅婷 API Key 無效或已過期。"),
            (429, "{}", "雅婷請求太頻繁，請稍後再試。"),
            (503, "{}", "雅婷伺服器暫時故障，請稍後再試。"),
        ]
        for (status, body, message) in cases {
            let stt = recognizer(token: { _ in (status, body) }, afterEOF: [])
            do {
                _ = try await stt.transcribe(try file(), progress: nil)
                Issue.record("expected a failure for HTTP \(status)")
            } catch let error as SttError {
                #expect(error.message == message)
            }
        }
    }
}

@Suite struct LlmQuotaTests {
    func client(_ status: Int, _ body: String) -> OpenAICompatibleLlmClient {
        OpenAICompatibleLlmClient(config: ProviderRegistry.llmPresets["openai"]!, apiKey: "k", client: FakeHTTP { _ in (status, body) })
    }

    @Test func insufficientQuotaIsBillingNotRateLimit() async {
        do {
            _ = try await client(429, #"{"error":{"code":"insufficient_quota"}}"#).complete([LlmMessage("user", "hi")])
            Issue.record("expected failure")
        } catch let error as AIServiceError {
            #expect(error.kind == .billing)
        } catch {
            Issue.record("unexpected \(error)")
        }
        do {
            _ = try await client(429, #"{"error":{"message":"Too many requests"}}"#).complete([LlmMessage("user", "hi")])
            Issue.record("expected failure")
        } catch let error as AIServiceError {
            #expect(error.kind == .rateLimit)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

// MARK: Service health

@Suite struct ServiceHealthTests {
    let base: [String: String] = [
        ConfigKey.llmProvider: "openai", "OPENAI_API_KEY": "k", "OPENAI_LLM_MODEL": "gpt-4o-mini",
        ConfigKey.imageProvider: "cloudflare", "CLOUDFLARE_IMAGE_APP_TOKEN": "t",
        "CLOUDFLARE_IMAGE_WORKER_URL": "https://worker.example",
        ConfigKey.speechProvider: "yating", "YATING_API_KEY": "y",
    ]

    func check(_ kind: ServiceKind, _ values: [String: String] = [:], respond: @escaping @Sendable (URLRequest) -> (Int, String)) async -> HealthResult {
        let config = ConfigStore(values: base.merging(values) { $1 })
        return await ServiceHealthChecker(config: config, http: FakeHTTP(respond: respond)).check(kind)
    }

    @Test func llm() async {
        #expect(await check(.llm) { _ in (200, #"{"choices":[{"message":{"content":"OK"}}]}"#) }.status == .ok)
        #expect(await check(.llm) { _ in (401, "{}") }.status == .invalidKey)
        #expect(await check(.llm) { _ in (429, #"{"error":{"code":"insufficient_quota"}}"#) }.status == .quotaExhausted)
        #expect(await check(.llm) { _ in (429, "{}") }.status == .rateLimited)
        #expect(await check(.llm) { _ in (404, "{}") }.status == .serverError)
        #expect(await check(.llm, ["OPENAI_API_KEY": ""]) { _ in (200, "{}") }.status == .notConfigured)
    }

    @Test func cloudflareTokenProbeNeverGenerates() async {
        let generations = LockedValue(0)
        let ok = await check(.image) { request in
            if request.url!.path.hasSuffix("/health") { return (200, #"{"status":"ok"}"#) }
            generations.withValue { $0 += 1 }
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain")
            return (415, "{}")
        }
        #expect(ok.status == .ok)
        #expect(generations.current == 1)
        let bad = await check(.image) { request in request.url!.path.hasSuffix("/health") ? (200, "{}") : (401, "{}") }
        #expect(bad.status == .invalidKey)
        let down = await check(.image) { _ in (502, "") }
        #expect(down.status == .serverError)
    }

    @Test func otherImageProvidersCannotConfirmQuota() async {
        let values = [ConfigKey.imageProvider: "openai"]
        #expect(await check(.image, values) { _ in (200, #"{"data":[]}"#) }.status == .unverifiable)
        #expect(await check(.image, values) { _ in (401, "{}") }.status == .invalidKey)
    }

    @Test func yating() async {
        #expect(await check(.speechRecognition) { _ in (201, #"{"success":true,"auth_token":"t"}"#) }.status == .ok)
        #expect(await check(.speechRecognition) { _ in (402, "{}") }.status == .quotaExhausted)
        #expect(await check(.speechRecognition) { _ in (401, "{}") }.status == .invalidKey)
        let audio = Data(count: 320).base64EncodedString()
        #expect(await check(.speechSynthesis) { _ in (201, #"{"audioContent":"\#(audio)"}"#) }.status == .ok)
        #expect(await check(.speechSynthesis) { _ in (200, "{}") }.status == .serverError)
    }

    @Test func historyKeepsLatestPerProvider() {
        let defaults = UserDefaults(suiteName: "reminicare-tests-\(UUID().uuidString)")!
        let history = HealthHistory(defaults: defaults)
        let first = HealthResult(kind: .llm, provider: "OpenAI", status: .invalidKey, checkedAt: Date(), durationMs: 1)
        history.save(first)
        var second = first
        second.status = .ok
        history.save(second)
        #expect(history.load().count == 1)
        #expect(history.latest(.llm, provider: "OpenAI")?.status == .ok)
        #expect(history.latest(.llm, provider: "Gemini") == nil)
    }
}

// MARK: App Log

@Suite struct AppLogDiagnosticsTests {
    @Test func newMetricsAppearInTheLine() throws {
        let log = AppLog(capacity: 10)
        log.record(.recording, .recordingStopped, bytes: 100, peakDb: -70, avgDb: -80, loudPercent: 0, zeroPercent: 100, sampleRate: 16_000, channels: 1, detail: "manual")
        let line = try #require(log.entries.first).line
        for part in ["平均=-80 dB", "有聲=0%", "全零=100%", "取樣率=16000 Hz", "聲道=1"] {
            #expect(line.contains(part))
        }
        log.record(.settings, .warning, detail: "not-a-code")
        #expect(log.entries.last?.detail == "unexpected")
    }

    @Test func everyVerdictAndHealthStatusHasALabel() {
        let verdicts: [WavInspection.Verdict] = [.fileMissing, .notWav, .incompleteFile, .formatMismatch, .tooShort, .digitalSilence, .micSilent, .tooQuiet]
        for verdict in verdicts { #expect(AppLog.detailLabels[verdict.rawValue] != nil) }
        let statuses: [HealthStatus] = [.ok, .notConfigured, .invalidKey, .quotaExhausted, .rateLimited, .unreachable, .serverError, .slow, .unverifiable]
        for status in statuses { #expect(AppLog.detailLabels[status.logCode] != nil) }
        for input in [AudioRouteSnapshot.Input.builtIn, .bluetooth, .wired, .usb, .other, .none] {
            #expect(AppLog.detailLabels[input.rawValue] != nil)
        }
    }
}

import Foundation
import Testing
@testable import ReminiCareKit

// MARK: Yating through the speech Worker

@Suite struct YatingWorkerSpeechTests {
    func recording(seconds: Double = 0.5) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "worker-\(UUID().uuidString).wav")
        try WavAudio.wav(pcm: sinePCM(db: -20, seconds: seconds), sampleRate: 16_000).write(to: url)
        return url
    }

    func recognizer(_ base: String = "https://speech.example", respond: @escaping @Sendable (URLRequest) -> (Int, String)) -> YatingWorkerRecognizer {
        var recognizer = YatingWorkerRecognizer { SpeechWorkerEndpoint(baseURL: base, token: "app-token") }
        recognizer.http = FakeHTTP(respond: respond)
        return recognizer
    }

    @Test func sendsRawPcmWithTheTokenInAHeader() async throws {
        let file = try recording()
        let seen = LockedValue<URLRequest?>(nil)
        let text = try await recognizer { request in
            seen.withValue { $0 = request }
            return (200, #"{"text":"我沒有織過布","sentences":1}"#)
        }.transcribe(file, progress: nil)
        #expect(text == "我沒有織過布")
        let request = try #require(seen.current)
        #expect(request.url?.absoluteString == "https://speech.example/v1/transcribe")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer app-token")
        #expect(request.url?.query == nil)
        // 0.5 s of 16 kHz mono 16-bit PCM, without the 44-byte WAV header.
        #expect(request.httpBody?.count == 16_000)
    }

    @Test func mapsWorkerCodes() async throws {
        let file = try recording()
        let cases: [(Int, String, SttErrorKind)] = [
            (401, "unauthorized", .authentication),
            (402, "quota", .authentication),
            (502, "upstream_auth", .authentication),
            (429, "rate_limited", .server),
            (502, "upstream_error", .server),
            (504, "upstream_timeout", .timeout),
            (400, "invalid_audio", .invalidAudio),
            (413, "too_large", .payloadTooLarge),
            (500, "something_new", .server),
        ]
        for (status, code, kind) in cases {
            do {
                _ = try await recognizer { _ in (status, #"{"error":"\#(code)"}"#) }.transcribe(file, progress: nil)
                Issue.record("expected \(code) to fail")
            } catch let error as SttError {
                #expect(error.kind == kind, "\(code)")
            }
        }
    }

    @Test func keepsPartialTextOfAnIncompleteResult() async throws {
        let file = try recording()
        do {
            _ = try await recognizer { _ in (504, #"{"error":"timeout","partial":"一半"}"#) }.transcribe(file, progress: nil)
            Issue.record("expected failure")
        } catch let error as SttError {
            #expect(error.kind == .incomplete)
            #expect(error.partialText == "一半")
        }
    }

    @Test func refusesPlainHttp() async throws {
        let file = try recording()
        let calls = LockedValue(0)
        await #expect(throws: SttError.self) {
            _ = try await recognizer("http://speech.example") { _ in
                calls.withValue { $0 += 1 }
                return (200, "{}")
            }.transcribe(file, progress: nil)
        }
        #expect(calls.current == 0)
    }

    @Test func waitCoversRealTimeStreaming() {
        let recognizer = YatingWorkerRecognizer { SpeechWorkerEndpoint(baseURL: "https://x.example", token: "t") }
        // 60 s of audio streams in 60 s, plus the completion wait.
        #expect(recognizer.timeout(bytes: 16_000 * 2 * 60) == .seconds(105))
    }

    @Test func synthesizesThroughTheWorker() async {
        let audio = Data(count: 320).base64EncodedString()
        var synthesizer = YatingWorkerSynthesizer { SpeechWorkerEndpoint(baseURL: "https://speech.example/", token: "app-token") }
        let body = LockedValue<[String: String]>([:])
        synthesizer.http = FakeHTTP { request in
            #expect(request.url?.absoluteString == "https://speech.example/v1/speeches")
            body.withValue { $0 = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String] ?? [:] }
            return (200, #"{"audioContent":"\#(audio)"}"#)
        }
        let wav = await synthesizer.synthesize("你好", language: .taiwanese)
        #expect(wav?.count == 44 + 320)
        #expect(body.current == ["text": "你好", "language": "taiwanese"])
        synthesizer.http = FakeHTTP { _ in (401, #"{"error":"unauthorized"}"#) }
        let failed = await synthesizer.synthesizeReporting("你好", language: .mandarin)
        #expect(failed.audio == nil && failed.detail == "worker_unauthorized")
    }

    @Test func everyWorkerCodeHasALabel() {
        for code in ["unauthorized", "rate_limited", "quota", "upstream_auth", "upstream_rate_limit", "upstream_error",
                     "upstream_invalid", "upstream_unreachable", "upstream_timeout", "upstream_closed", "timeout",
                     "invalid_audio", "too_large", "misconfigured", "unknown"] {
            #expect(AppLog.detailLabels["worker_\(code)"] != nil, "\(code)")
        }
        for code in ["speechWorkerTranscribe", "speechWorkerSpeech", "sttRetry", "sttRetryEmpty", "sttRetrySucceeded",
                     "llmFallback_nvidia", "llmFallback_openai", "llmFallback_gemini", "llmFallback_groq",
                     "updateCheck", "updateAvailable", "updateNone", "updateFailed", "updateOpenAltStore", "updateOpenPage"] {
            #expect(AppLog.detailLabels[code] != nil, "\(code)")
        }
    }

    @Test func factoryPicksTheProvider() {
        func recognizer(_ speech: String) -> SpeechRecognizer {
            ServiceFactory(config: ConfigStore(values: [ConfigKey.speechProvider: speech])).baseRecognizer()
        }
        #expect(recognizer("yating") is YatingWorkerRecognizer)
        #expect(recognizer("") is YatingWorkerRecognizer)
        #expect(recognizer("yatingDirect") is YatingSpeechRecognizer)
        #expect(recognizer("ncku") is NckuSpeechRecognizer)
        #expect(ServiceFactory(config: ConfigStore(values: [:])).recognizer() is RetryingSpeechRecognizer)
    }
}

// MARK: Automatic retry

@Suite struct RetryingSpeechRecognizerTests {
    let file = URL(fileURLWithPath: "/tmp/unused.wav")

    func retrying(_ results: [Result<String, Error>]) -> (RetryingSpeechRecognizer, FakeRecognizer) {
        let fake = FakeRecognizer([])
        fake.results.withValue { $0 = results }
        return (RetryingSpeechRecognizer(fake, delay: .zero), fake)
    }

    @Test func retriesOnceAfterANetworkError() async throws {
        let (recognizer, fake) = retrying([.failure(SttError(.network, "x")), .success("好")])
        #expect(try await recognizer.transcribe(file, progress: nil) == "好")
        #expect(fake.calls.current == 2)
    }

    @Test func retriesOnceAfterAnEmptyResult() async throws {
        let (recognizer, fake) = retrying([.success(" "), .success("有了")])
        #expect(try await recognizer.transcribe(file, progress: nil) == "有了")
        #expect(fake.calls.current == 2)
    }

    @Test func givesUpAfterOneRetry() async throws {
        let (recognizer, fake) = retrying([.failure(SttError(.timeout, "x")), .failure(SttError(.timeout, "y"))])
        await #expect(throws: SttError.self) { _ = try await recognizer.transcribe(file, progress: nil) }
        #expect(fake.calls.current == 2)
        let (empty, emptyFake) = retrying([.success(""), .success("")])
        #expect(try await empty.transcribe(file, progress: nil) == "")
        #expect(emptyFake.calls.current == 2)
    }

    @Test func doesNotRetryWhatWouldFailAgain() async throws {
        for error in [SttError(.authentication, "key"), SttError(.invalidAudio, "audio"), SttError(.payloadTooLarge, "big"),
                      SttError(.cancelled, "cancel"), SttError(.incomplete, "half", partialText: "一半")] {
            let (recognizer, fake) = retrying([.failure(error), .success("不該用到")])
            await #expect(throws: SttError.self) { _ = try await recognizer.transcribe(file, progress: nil) }
            #expect(fake.calls.current == 1, "\(error.kind)")
        }
    }
}

// MARK: LLM fallback

@Suite struct FallbackLlmClientTests {
    struct Failing: LlmClient {
        let error: AIServiceError
        let calls = LockedValue(0)
        func complete(messages: [LlmMessage], temperature: Double, maxTokens: Int, jsonObject: Bool) async throws -> String {
            calls.withValue { $0 += 1 }
            throw error
        }
    }

    @Test func movesOnWhenAProviderIsLimitedOrDown() async throws {
        for kind in [AIErrorKind.rateLimit, .billing, .timeout, .network, .invalidResponse, .authentication] {
            let client = FallbackLlmClient([
                .init(providerId: "groq", client: Failing(error: AIServiceError(kind, "x"))),
                .init(providerId: "nvidia", client: FakeLlm("備援回答")),
            ])
            #expect(try await client.complete([LlmMessage("user", "hi")]) == "備援回答", "\(kind)")
        }
    }

    @Test func aCancelStopsTheChain() async throws {
        let backup = Failing(error: AIServiceError(.network, "never"))
        let client = FallbackLlmClient([
            .init(providerId: "groq", client: Failing(error: AIServiceError(.cancelled, "x"))),
            .init(providerId: "nvidia", client: backup),
        ])
        await #expect(throws: AIServiceError.self) { _ = try await client.complete([LlmMessage("user", "hi")]) }
        #expect(backup.calls.current == 0)
    }

    @Test func reportsTheFirstErrorWhenAllFail() async throws {
        let client = FallbackLlmClient([
            .init(providerId: "groq", client: Failing(error: AIServiceError(.rateLimit, "first"))),
            .init(providerId: "nvidia", client: Failing(error: AIServiceError(.network, "second"))),
        ])
        do {
            _ = try await client.complete([LlmMessage("user", "hi")])
            Issue.record("expected failure")
        } catch let error as AIServiceError {
            #expect(error.kind == .rateLimit)
        }
    }

    @Test func factoryAddsOnlyProvidersWithKeys() throws {
        let config = ConfigStore(values: [
            ConfigKey.llmProvider: "groq", "GROQ_API_KEY": "g", "NVIDIA_API_KEY": "n", "OPENAI_API_KEY": " ",
            "NVIDIA_LLM_MODEL": "custom/model",
        ])
        let client = try #require(ServiceFactory(config: config).llm() as? FallbackLlmClient)
        #expect(client.entries.map(\.providerId) == ["groq", "nvidia"])
        let nvidia = try #require(client.entries[1].client as? OpenAICompatibleLlmClient)
        #expect(nvidia.config.model == "custom/model")
        // A custom endpoint is only ever first.
        let custom = ConfigStore(values: [ConfigKey.llmProvider: "custom", "CUSTOM_LLM_API_KEY": "c", "GEMINI_API_KEY": "m"])
        let chain = try #require(ServiceFactory(config: custom).llm() as? FallbackLlmClient)
        #expect(chain.entries.map(\.providerId) == ["custom", "gemini"])
    }
}

// MARK: Update check

@Suite struct UpdateCheckerTests {
    func release(_ tag: String, ipa: Bool = true, prerelease: Bool = false) -> String {
        let assets = ipa
            ? #"[{"name":"ReminiCare-\#(tag).ipa","browser_download_url":"https://github.com/o/r/releases/download/\#(tag)/ReminiCare-\#(tag).ipa"}]"#
            : "[]"
        return #"{"tag_name":"\#(tag)","html_url":"https://github.com/o/r/releases/tag/\#(tag)","body":"修正辨識","draft":false,"prerelease":\#(prerelease),"assets":\#(assets)}"#
    }

    func check(current: String, _ body: String, status: Int = 200) async -> UpdateCheckResult {
        await UpdateChecker(currentVersion: current, http: FakeHTTP { request in
            #expect(request.url == UpdateChecker.latestReleaseURL)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (status, body)
        }).check()
    }

    @Test func comparesVersionsNumerically() {
        #expect(AppVersion("2.0.10")! > AppVersion("2.0.9")!)
        #expect(AppVersion("v2.1")! > AppVersion("2.0.9")!)
        #expect(AppVersion("2.0")! == AppVersion("2.0.0")!)
        #expect(AppVersion("2.0.x") == nil)
    }

    @Test func offersANewerRelease() async throws {
        guard case .available(let info) = await check(current: "2.0.2", release("v2.0.3")) else {
            Issue.record("expected an update")
            return
        }
        #expect(info.version == "2.0.3")
        #expect(info.notes == "修正辨識")
        let altStore = try #require(info.altStoreURL)
        #expect(altStore.absoluteString
            == "altstore://install?url=https%3A%2F%2Fgithub.com%2Fo%2Fr%2Freleases%2Fdownload%2Fv2.0.3%2FReminiCare-v2.0.3.ipa")
    }

    @Test func sameOrOlderIsUpToDate() async {
        #expect(await check(current: "2.0.3", release("v2.0.3")) == .upToDate(latest: "2.0.3"))
        #expect(await check(current: "2.1.0", release("v2.0.3")) == .upToDate(latest: "2.0.3"))
    }

    @Test func badAnswersFail() async {
        #expect(await check(current: "2.0.2", "{}", status: 404) == .failed)
        #expect(await check(current: "2.0.2", "not json") == .failed)
        #expect(await check(current: "2.0.2", release("v2.0.3", prerelease: true)) == .failed)
    }

    @Test func aReleaseWithoutIpaFallsBackToThePage() async {
        guard case .available(let info) = await check(current: "2.0.2", release("v2.0.3", ipa: false)) else {
            Issue.record("expected an update")
            return
        }
        #expect(info.altStoreURL == nil)
        #expect(info.pageURL.absoluteString == "https://github.com/o/r/releases/tag/v2.0.3")
    }

    @Test func launchOfferRespectsSkipAndDailyLimit() {
        let defaults = UserDefaults(suiteName: "reminicare-tests-\(UUID().uuidString)")!
        let preferences = UpdatePreferences(defaults: defaults)
        let info = UpdateInfo(version: "2.0.3", notes: "", ipaURL: nil, pageURL: URL(string: "https://x.example")!)
        #expect(preferences.launchOffer(.available(info)) == info)
        preferences.skip("2.0.3")
        #expect(preferences.launchOffer(.available(info)) == nil)
        #expect(preferences.launchOffer(.upToDate(latest: "2.0.3")) == nil)

        let now = Date()
        #expect(preferences.shouldCheck(now: now))
        preferences.markChecked(now: now)
        #expect(!preferences.shouldCheck(now: now.addingTimeInterval(3_600)))
        #expect(preferences.shouldCheck(now: now.addingTimeInterval(25 * 3_600)))
    }
}

@Suite struct NckuTaiwaneseTtsTests {
    struct RecordingTCP: TCPExchanging {
        let seen = LockedValue<[(port: Int, message: String)]>([])
        func exchange(host: String, port: Int, tls: Bool, payload: Data, timeout: Duration, maximumBytes: Int) async throws -> Data {
            seen.withValue { $0.append((port, String(decoding: payload, as: UTF8.self))) }
            let wav = Data("RIFF....WAVEfmt ".utf8).base64EncodedString()
            return Data(#"{"status":true,"bytes":"\#(wav)"}"#.utf8)
        }
    }

    @Test func taiwaneseGoesTo9986AndMandarinStaysOnTheConfiguredPort() async {
        let tcp = RecordingTCP()
        let tts = NckuSpeechSynthesizer(host: "tts.example", port: 9998, tls: false, token: { "t" }, fallback: .off, taiLo: nil)
        tts.tcp = tcp
        #expect(await tts.synthesize("阿公佇菜市仔", language: .taiwanese) != nil)
        #expect(await tts.synthesize("您好", language: .mandarin) != nil)
        let seen = tcp.seen.current
        #expect(seen.map(\.port) == [9986, 9998])
        #expect(seen.first?.message == "10012@@@t@@@tw@@@0@@@阿公佇菜市仔EOT")
        #expect(seen.last?.message.contains("@@@zh@@@4793@@@") == true)
    }
}

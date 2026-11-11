import Foundation
import Testing
@testable import ReminiCareKit

@Suite struct WavAudioTests {
    @Test func roundTripAndSplitCoverEverySample() throws {
        let pcm = Data((0..<(WavAudio.bytesPerSecond * 12)).map { UInt8($0 % 251) })
        let parsed = try WavAudio.parse(WavAudio(pcm: pcm).encode())
        #expect(parsed.pcm == pcm)
        let segments = parsed.split()
        #expect(segments.count == 3)
        #expect(segments.reduce(Data()) { $0 + $1.pcm } == pcm)
        #expect(segments.dropLast().allSatisfy { $0.pcm.count > WavAudio.bytesPerSecond })
    }

    @Test func fiveSecondSegmentsAreSentWhole() {
        // Speech with pauses: loud tone for 0.5 s, then near-silence (small negatives encode to "/").
        var pcm = Data()
        for i in 0..<(WavAudio.bytesPerSecond * 5 / 2) {
            let value = (i / 8000) % 2 == 0 ? Int16(3000 * sin(Double(i) * 2 * .pi * 220 / 16000)) : Int16(i * 7 % 7 - 3)
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let recognizer = NckuSpeechRecognizer(token: { String(repeating: "x", count: 40) }, endpoint: URL(string: "https://stt.example")!)
        #expect(recognizer.body(for: WavAudio(pcm: pcm)).count <= NckuSpeechRecognizer.maximumBodyBytes)
        // Halving for a 413 cuts near the middle and covers every sample.
        let parts = WavAudio(pcm: pcm).split(maximumBytes: (pcm.count / 4) * 2 + WavAudio.bytesPerSecond / 4)
        #expect(parts.count == 2)
        #expect(parts.reduce(Data()) { $0 + $1.pcm } == pcm)
    }

    @Test func acceptsExtensiblePcmAndExtraChunks() throws {
        var fmt = Data()
        func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { fmt.append(contentsOf: $0) } }
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { fmt.append(contentsOf: $0) } }
        le16(0xFFFE); le16(1); le32(16_000); le32(32_000); le16(2); le16(16); le16(22); le16(16); le32(4)
        fmt.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        let pcm = Data(count: 640)
        var body = Data("WAVE".utf8)
        func chunk(_ id: String, _ payload: Data) {
            body.append(Data(id.utf8))
            withUnsafeBytes(of: UInt32(payload.count).littleEndian) { body.append(contentsOf: $0) }
            body.append(payload)
        }
        chunk("fmt ", fmt)
        chunk("FLLR", Data(count: 12))
        chunk("data", pcm)
        var file = Data("RIFF".utf8)
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { file.append(contentsOf: $0) }
        file.append(body)
        #expect(try WavAudio.parse(file).pcm == pcm)
    }

    @Test func rejectsWrongRateAndTruncation() {
        var wav = WavAudio(pcm: Data(count: 64)).encode()
        wav[24] = 0x44 // sample rate 16000 -> other
        #expect(throws: WavAudio.FormatError.self) { try WavAudio.parse(wav) }
        let truncated = WavAudio(pcm: Data(count: 64)).encode().dropLast(10)
        #expect(throws: WavAudio.FormatError.self) { try WavAudio.parse(Data(truncated)) }
    }
}

@Suite struct ParserTests {
    @Test func picksLastCompleteObjectWithKey() throws {
        let text = #"draft {"x":1} then {"surname":"王","title":"先生"} {"surname":"#
        let object = try ProviderResponseParser.decodeJSONObject(text, requiredKey: "surname")
        #expect(object["surname"] as? String == "王")
    }

    @Test func ignoresReasoningOnlyResponses() {
        let decoded: [String: Any] = ["choices": [["message": ["content": "", "reasoning_content": "thinking"]]]]
        #expect(ProviderResponseParser.messageText(decoded) == nil)
        let ok: [String: Any] = ["choices": [["message": ["content": [["type": "text", "text": " 你好 "]]]]]]
        #expect(ProviderResponseParser.messageText(ok) == "你好")
    }
}

@Suite struct NameTests {
    func name(_ json: String, _ transcript: String) async throws -> String {
        try await ReminiscenceAI(client: FakeLlm(json)).elderName(from: transcript)
    }

    @Test func keepsSurnameAndSpokenTitle() async throws {
        #expect(try await name(#"{"surname":"王","title":"先生"}"#, "我叫王小明，叫我王先生。") == "王先生")
        #expect(try await name(#"{"surname":"丁","title":null}"#, "我叫丁紅圓") == "丁長輩")
        #expect(try await name(#"{"surname":"歐陽","title":"女士"}"#, "我叫歐陽秀，請叫我歐陽女士") == "歐陽女士")
    }

    @Test func unclearOrMisheardTitlesFallBack() async throws {
        #expect(try await name(#"{"surname":"丁","title":"小姐"}"#, "我叫丁紅圓") == "丁長輩")
        #expect(try await name(#"{"surname":"陳","title":"阿嬤"}"#, "我是陳阿媽") == "陳阿嬤")
        #expect(try await name(#"{"surname":"陳","title":"阿嬤"}"#, "我姓陳，叫我陳拉瑪") == "陳長輩")
        #expect(try await name(#"{"surname":"林","title":"姊姊"}"#, "叫我林姐姐") == "林姊姊")
    }

    @Test func rejectsSurnamesNotInTranscript() async {
        for reply in [#"{"surname":null,"title":null}"#, #"{"surname":"陳","title":null}"#, #"{"surname":"丁紅","title":null}"#, "not json"] {
            await #expect(throws: AIServiceError.self) { try await name(reply, "我叫丁紅圓") }
        }
    }

    @Test func heardNameStripsIntroductionPhrases() {
        #expect(ReminiscenceAI.heardName("我叫家燕") == "家燕")
        #expect(ReminiscenceAI.heardName("叫做無家") == "無家")
        #expect(ReminiscenceAI.heardName("大家好，我是陳拉瑪。") == "陳拉瑪")
        #expect(ReminiscenceAI.heardName("我叫") == "")
        #expect(ReminiscenceAI.heardName("我叫王小明今天很開心") == "王小明今天很")
    }

    @Test func participantAddress() {
        #expect(ParticipantAddress.candidates(for: "於") == ["於", "余", "于", "俞"])
        #expect(ParticipantAddress.fromDisplayName("歐陽女士") == ParticipantAddress("歐陽", "女士"))
        #expect(ParticipantAddress("第五", "長輩").isValid)
        #expect(!ParticipantAddress("", "先生").isValid)
        #expect(!ParticipantAddress("余先生", "先生").isValid)
    }
}

@Suite struct SpeechServiceTests {
    @Test func classifiesNckuBackendErrors() {
        let refused = #"{"error":"HTTPConnectionPool(host='140.116.245.154', port=9001): Failed to establish a new connection: [Errno 113] No route to host"}"#
        #expect(nckuSttErrorDetail(statusCode: 500, body: refused) == "sttBackendRefused")
        #expect(nckuSttErrorDetail(statusCode: 500, body: #"{"error":"Read timed out"}"#) == "sttBackendTimeout")
        #expect(nckuSttErrorDetail(statusCode: 500, body: #"{"error":"boom"}"#) == "sttBackendError")
        #expect(nckuSttErrorDetail(statusCode: 503, body: "") == "server")
        #expect(nckuSttErrorDetail(statusCode: 413, body: "") == "payloadTooLarge")
    }

    @Test func taiLoNormalization() {
        #expect(containsHan("阿嬤"))
        #expect(!containsHan("a-má"))
        #expect(normalizeTaiLo("Lí hó ， tsia̍h-pá buē？") == "Lí hó, tsia̍h-pá buē?")
        #expect(normalizeTaiLo("阿嬤 hó") == nil)
        #expect(normalizeTaiLo("123") == nil)
    }

    @Test func pauseDetector() {
        var detector = SpeechPauseDetector(silenceTimeout: .seconds(2))
        let results = [
            detector.sample(elapsed: .milliseconds(200), loud: true),
            detector.sample(elapsed: .milliseconds(400), loud: true),
            detector.sample(elapsed: .milliseconds(2000), loud: false),
            detector.sample(elapsed: .milliseconds(2400), loud: false),
        ]
        #expect(results == [false, false, false, true])
        #expect(detector.hasSpoken)
        var idle = SpeechPauseDetector(silenceTimeout: .seconds(2), idleTimeout: .seconds(1))
        let stopped = idle.sample(elapsed: .seconds(1), loud: false)
        #expect(stopped)
        #expect(!idle.hasSpoken)
    }

    @Test func ttsCacheSeparatesProvidersAndCoalesces() async throws {
        let cache = TtsCache(directory: try temporaryDirectory())
        let synthesizer = CountingSynthesizer()
        async let a = cache.resolve("你好", language: .mandarin, identity: "p1", synthesizer: synthesizer)
        async let b = cache.resolve("你好", language: .mandarin, identity: "p1", synthesizer: synthesizer)
        let (first, second) = await (a, b)
        #expect(first != nil && first == second)
        #expect(synthesizer.calls.current == 1)
        _ = await cache.resolve("你好", language: .mandarin, identity: "p1", synthesizer: synthesizer)
        #expect(synthesizer.calls.current == 1)
        _ = await cache.resolve("你好", language: .mandarin, identity: "p2", synthesizer: synthesizer)
        #expect(synthesizer.calls.current == 2)
        #expect(await cache.entries().count == 2)
        await cache.clear()
        #expect(await cache.entries().isEmpty)
    }
}

@Suite struct ConfigTests {
    func store() -> (ConfigStore, MemorySecretStore) {
        let defaults = UserDefaults(suiteName: "reminicare-tests-\(UUID().uuidString)")!
        let secrets = MemorySecretStore()
        return (ConfigStore(defaults: defaults, secrets: secrets), secrets)
    }

    @Test func defaultsAndValidation() throws {
        let (config, _) = store()
        try config.load()
        #expect(config.value(ConfigKey.speechProvider) == "yating")
        #expect(config.value("NCKU_STT_URL") == ConfigKey.defaultNckuSttURL)
        #expect(config.validate([:]) == "目前語言模型的 API Key 不可空白")
        let valid = ["NVIDIA_API_KEY": "k", "CLOUDFLARE_IMAGE_APP_TOKEN": "t", ConfigKey.speechWorkerToken: "w"]
        #expect(config.validate(valid) == nil)
        #expect(config.value(ConfigKey.speechWorkerURL) == ConfigKey.defaultSpeechWorkerURL)
        #expect(config.validate(valid.merging([ConfigKey.speechWorkerToken: ""]) { $1 }) == "語音 Worker App Token 不可空白")
        #expect(config.validate(valid.merging([ConfigKey.speechWorkerURL: "http://x.example"]) { $1 }) == "語音 Worker 網址必須是有效的 HTTPS 網址")
        // Direct Yating needs this iPad's own key instead.
        #expect(config.validate(valid.merging([ConfigKey.speechProvider: "yatingDirect"]) { $1 }) == "雅婷語音服務 Token 不可空白")
        #expect(config.validate(valid.merging([ConfigKey.speechProvider: "yatingDirect", "YATING_API_KEY": "y"]) { $1 }) == nil)
        #expect(config.validate(valid.merging([ConfigKey.introSilence: "0.5"]) { $1 }) != nil)
        #expect(config.validate(valid.merging([ConfigKey.speechProvider: "ncku"]) { $1 }) == "NCKU 語音服務需要 TTS 與 STT Token")
    }

    @Test func secretsGoToSecretStoreAndFailedSavesRollBack() throws {
        let (config, secrets) = store()
        try config.load()
        try config.save(["NVIDIA_API_KEY": " key ", ConfigKey.llmProvider: "openai"])
        #expect(try secrets.read("NVIDIA_API_KEY") == "key")
        #expect(config.value(ConfigKey.llmProvider) == "openai")
        secrets.failWrites = true
        #expect(throws: KeychainError.self) { try config.save(["NVIDIA_API_KEY": "new", ConfigKey.llmProvider: "gemini"]) }
        #expect(try secrets.read("NVIDIA_API_KEY") == "key")
        #expect(config.value(ConfigKey.llmProvider) == "openai")
    }
}

@Suite struct RepositoryTests {
    @Test func catalogHasBundledImages() throws {
        let catalog = try TopicCatalog.load()
        #expect(catalog.topics.count >= 4)
        #expect(catalog.topics.allSatisfy { $0.imageURL != nil })
        let picked = catalog.pickFour(excluding: Set(catalog.topics.prefix(4).map(\.topicId)))
        #expect(Set(picked.map(\.topicId)).isDisjoint(with: catalog.topics.prefix(4).map(\.topicId)))
    }

    @Test func savesLoadsAndDeletesWithImages() async throws {
        let root = try temporaryDirectory()
        let repository = MemoryRepository(root: root)
        let store = LocalImageStore(root: root)
        let kept = try #require(repository.relativePath(store.save(Data([1]), prefix: "a")))
        let draft = try #require(repository.relativePath(store.save(Data([2]), prefix: "b")))
        let record = MemoryRecord(id: "m-1", date: "2026/11/07", topic: "柑仔店", content: "內容", elders: "王先生",
                                  imagePath: kept, createdAt: Date(), keywords: [], turns: [], imageVersions: [kept, draft])
        try await repository.save(record)
        try await repository.save(record)
        #expect(try await repository.load().count == 1)
        await repository.discardImages([kept])
        #expect(FileManager.default.fileExists(atPath: repository.imageURL(kept)!.path))
        try await repository.delete("m-1")
        #expect(try await repository.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repository.imageURL(kept)!.path))
        #expect(!FileManager.default.fileExists(atPath: repository.imageURL(draft)!.path))
    }
}

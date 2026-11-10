import Foundation
import Testing
@testable import ReminiCareKit

private let question = "你有沒有織過布？"
private let misheard = "我沒有字過，不"
private let fixed = "我沒有織過布"

private struct SlowLlm: LlmClient {
    func complete(messages: [LlmMessage], temperature: Double, maxTokens: Int, jsonObject: Bool) async throws -> String {
        try await Task.sleep(for: .seconds(5))
        return #"{"text":"太慢了"}"#
    }
}

@Suite struct TranscriptCorrectionValidationTests {
    @Test func acceptsAHomophoneFix() {
        #expect(ReminiscenceAI.validateCorrection(#"{"text":"我沒有織過布"}"#, original: misheard, question: question) == fixed)
    }

    @Test func rejectsUnusableOrRewrittenReplies() {
        let original = misheard
        #expect(ReminiscenceAI.validateCorrection("我沒有織過布", original: original, question: question) == nil)
        #expect(ReminiscenceAI.validateCorrection(#"{"text":"  "}"#, original: original, question: question) == nil)
        #expect(ReminiscenceAI.validateCorrection(#"{"other":"x"}"#, original: original, question: question) == nil)
        let padded = #"{"text":"我沒有織過布，但是我媽媽以前每天都在家裡織布給全家人穿"}"#
        #expect(ReminiscenceAI.validateCorrection(padded, original: original, question: question) == nil)
        #expect(ReminiscenceAI.validateCorrection(#"{"text":"我1960年沒有織過布"}"#, original: original, question: question) == nil)
    }

    @Test func checksEachListedChange() {
        let good = #"{"changes":[{"from":"吃過，不","to":"織過布","pinyin":"chī guò bù → zhī guò bù"}],"text":"我沒有織過布"}"#
        #expect(ReminiscenceAI.validateCorrection(good, original: "我沒有吃過，不", question: question) == fixed)
        let invented = #"{"changes":[{"from":"喝過","to":"織過","pinyin":""}],"text":"我沒有織過布"}"#
        #expect(ReminiscenceAI.validateCorrection(invented, original: "我沒有吃過，不", question: question) == nil)
        let rewritten = #"{"changes":[{"from":"不","to":"織布的經驗","pinyin":""}],"text":"我沒有吃過織布的經驗"}"#
        #expect(ReminiscenceAI.validateCorrection(rewritten, original: "我沒有吃過，不", question: question) == nil)
        let none = #"{"changes":[],"text":"我沒有織過布"}"#
        #expect(ReminiscenceAI.validateCorrection(none, original: fixed, question: question) == fixed)
    }

    @Test func keepsNumbersThatWereSaid() {
        let original = "我1960年在台南織布"
        #expect(ReminiscenceAI.validateCorrection(#"{"text":"我1960年在台南織布"}"#, original: original, question: question) == original)
    }

    @Test func simplifiedRepliesBecomeTraditional() async throws {
        #expect(ReminiscenceAI.traditional("记得以前在台南的菜市场买菜吗？") == "記得以前在台南的菜市場買菜嗎？")
        #expect(ReminiscenceAI.traditional("還記得裡面的台灣小吃嗎？") == "還記得裡面的台灣小吃嗎？")
        let ai = ReminiscenceAI(client: FakeLlm("那时候您最喜欢吃什么？"))
        #expect(try await ai.extendedQuestion(previous: "q", response: "a") == "那時候您最喜歡吃什麼？")
    }

    @Test func reportsEachOutcome() async {
        let corrected = ReminiscenceAI(client: FakeLlm(#"{"text":"我沒有織過布"}"#))
        #expect(await corrected.correctTranscript(question: question, transcript: misheard) == .corrected(fixed))
        let same = ReminiscenceAI(client: FakeLlm(#"{"text":"我沒有織過布"}"#))
        #expect(await same.correctTranscript(question: question, transcript: fixed) == .unchanged)
        let failing = ReminiscenceAI(client: FakeLlm { _ in throw AIServiceError(.network, "offline") })
        #expect(await failing.correctTranscript(question: question, transcript: misheard) == .failed)
        let slow = ReminiscenceAI(client: SlowLlm())
        #expect(await slow.correctTranscript(question: question, transcript: misheard, timeout: .milliseconds(50)) == .timedOut)
    }
}

@MainActor
@Suite struct TranscriptCorrectionFlowTests {
    struct Harness {
        let session: LifeSession
        let voice: FakeVoice
        let image: FakeImage
        let correctionRequests: LockedValue<[String]>
        let sceneRequests: LockedValue<[String]>
    }

    func make(
        transcripts: [String], correction: Bool = true, confirmation: Bool = false, settings: [String: String] = [:],
        correct: @escaping @Sendable (String) throws -> String = { _ in #"{"text":"我沒有織過布"}"# }
    ) throws -> Harness {
        let root = try temporaryDirectory()
        let defaults = UserDefaults(suiteName: "reminicare-tests-\(UUID().uuidString)")!
        defaults.set(correction ? "true" : "false", forKey: ConfigKey.transcriptCorrection)
        defaults.set(confirmation ? "true" : "false", forKey: ConfigKey.transcriptConfirmation)
        for (key, value) in settings { defaults.set(value, forKey: key) }
        let config = ConfigStore(defaults: defaults, secrets: MemorySecretStore())
        try config.load()
        let voice = FakeVoice(directory: root)
        let image = FakeImage(store: LocalImageStore(root: root))
        let requests = LockedValue<[String]>([])
        let scenes = LockedValue<[String]>([])
        let llm = FakeLlm { messages in
            let system = messages.first?.content ?? ""
            let user = messages.last?.content ?? ""
            if system.contains("台語翻譯") { return #"{"text":"我小時候常常去溪邊抓魚"}"# }
            if system.contains("語音辨識校對員") {
                requests.withValue { $0.append(user) }
                return try correct(user)
            }
            if system.contains("姓氏") { return #"{"surname":"王","title":"先生"}"# }
            if user.contains("topicId") { throw AIServiceError(.network, "offline") }
            if system.contains("scene") {
                scenes.withValue { $0.append(user) }
                return #"{"scene":"weaving","era":"1970s","location":"Tainan","keywords":["織布"]}"#
            }
            return "還記得是誰教您的嗎？"
        }
        let session = LifeSession(
            config: config, ai: ReminiscenceAI(client: llm), image: image,
            recognizer: FakeRecognizer(transcripts), memories: MemoryRepository(root: root), voice: { voice }
        )
        return Harness(session: session, voice: voice, image: image, correctionRequests: requests, sceneRequests: scenes)
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Introduction done, now on the first question.
    func reachQuestion(_ h: Harness) async throws {
        await h.session.initialize()
        h.session.selectTopic(h.session.topics[0])
        await h.session.startIntroductionRecording()
        await h.voice.finishRecording()
        try await waitUntil { h.session.introductionState == .confirmed }
        await h.session.finishIntroduction()
        #expect(h.session.stage == .question)
    }

    func answer(_ h: Harness, until stage: LifeStage) async throws {
        await h.session.startAnswerRecording()
        await h.voice.finishRecording()
        try await waitUntil { h.session.stage == stage }
        #expect(h.session.stage == stage)
    }

    @Test func correctedTextMakesThePhotoAndKeepsTheRawText() async throws {
        let h = try make(transcripts: ["我叫王小明，叫我王先生", misheard])
        try await reachQuestion(h)
        #expect(h.correctionRequests.current.isEmpty, "自我介紹不校正")
        try await answer(h, until: .evaluation)
        #expect(h.image.calls.current == 1)
        #expect(h.session.turns.last?.text == fixed)
        #expect(h.session.turns.last?.rawText == misheard)
        #expect(h.session.transcript == fixed)
        let request = try #require(h.correctionRequests.current.first)
        #expect(request.contains(h.session.turns[0].question))
        #expect(request.contains(misheard))
        #expect(request.contains("聊天主題：\(h.session.topics[0].title)"))
        let scene = try #require(h.sceneRequests.current.first)
        #expect(scene.contains("主題：\(h.session.topics[0].title)"))
        #expect(scene.contains("問：\(h.session.turns[0].question)"))
        #expect(scene.contains("答：\(fixed)"))
    }

    @Test func failedCorrectionContinuesWithTheOriginal() async throws {
        let h = try make(transcripts: ["我叫王小明", misheard]) { _ in throw AIServiceError(.timeout, "slow") }
        try await reachQuestion(h)
        try await answer(h, until: .evaluation)
        #expect(h.session.errorMessage == nil)
        #expect(h.session.turns.last?.text == misheard)
        #expect(h.session.turns.last?.rawText == nil)
    }

    @Test func correctionOffLeavesTheTextAlone() async throws {
        let h = try make(transcripts: ["我叫王小明", misheard], correction: false)
        try await reachQuestion(h)
        try await answer(h, until: .evaluation)
        #expect(h.correctionRequests.current.isEmpty)
        #expect(h.session.turns.last?.text == misheard)
    }

    @Test func confirmationWaitsBeforeMakingThePhoto() async throws {
        let h = try make(transcripts: ["我叫王小明", misheard], confirmation: true)
        try await reachQuestion(h)
        try await answer(h, until: .transcriptConfirmation)
        #expect(h.image.calls.current == 0)
        #expect(h.session.turns.isEmpty)
        #expect(h.session.heardTranscript == fixed)
        #expect(h.session.rawTranscript == misheard)
        #expect(!h.session.confirmingRevision)
        await h.session.confirmTranscript()
        #expect(h.session.stage == .evaluation)
        #expect(h.image.calls.current == 1)
        #expect(h.session.turns.last?.text == fixed)
        #expect(h.session.heardTranscript.isEmpty)
    }

    @Test func editedTextIsUsedAndRawTextKept() async throws {
        let h = try make(transcripts: ["我叫王小明", misheard], correction: false, confirmation: true)
        try await reachQuestion(h)
        try await answer(h, until: .transcriptConfirmation)
        #expect(h.session.heardTranscript == misheard)
        await h.session.submitEditedTranscript("   ")
        #expect(h.session.stage == .transcriptConfirmation)
        await h.session.submitEditedTranscript(" 我沒有織過布 ")
        #expect(h.session.stage == .evaluation)
        #expect(h.session.turns.last?.text == fixed)
        #expect(h.session.turns.last?.rawText == misheard)
    }

    @Test func rerecordGoesBackToTheQuestion() async throws {
        let h = try make(transcripts: ["我叫王小明", misheard, fixed], correction: false, confirmation: true)
        try await reachQuestion(h)
        try await answer(h, until: .transcriptConfirmation)
        h.session.rerecordTranscript()
        #expect(h.session.stage == .question)
        #expect(h.session.turns.isEmpty)
        #expect(h.image.calls.current == 0)
        try await answer(h, until: .transcriptConfirmation)
        #expect(h.session.heardTranscript == fixed)
    }

    @Test func revisionRequestsAreConfirmedToo() async throws {
        let h = try make(transcripts: ["我叫王小明", misheard, "布的顏色要紅色"], correction: false, confirmation: true)
        try await reachQuestion(h)
        try await answer(h, until: .transcriptConfirmation)
        await h.session.confirmTranscript()
        h.session.chooseDislike()
        #expect(h.session.stage == .revisionRecording)
        await h.session.startRevisionRecording()
        await h.voice.finishRecording()
        try await waitUntil { h.session.stage == .transcriptConfirmation }
        #expect(h.session.confirmingRevision)
        h.session.rerecordTranscript()
        #expect(h.session.stage == .revisionRecording)
    }

    @Test func confirmedRevisionRevisesThePhoto() async throws {
        let h = try make(transcripts: ["我叫王小明", misheard, "布的顏色要紅色"], correction: false, confirmation: true)
        try await reachQuestion(h)
        try await answer(h, until: .transcriptConfirmation)
        await h.session.confirmTranscript()
        h.session.chooseDislike()
        await h.session.startRevisionRecording()
        await h.voice.finishRecording()
        try await waitUntil { h.session.stage == .transcriptConfirmation }
        await h.session.confirmTranscript()
        #expect(h.session.stage == .evaluation)
        #expect(h.image.calls.current == 2)
        #expect(h.session.turns.last?.kind == .correction)
        #expect(h.session.turns.last?.text == "布的顏色要紅色")
    }

    @Test func leavingDuringConfirmationDropsIt() async throws {
        let h = try make(transcripts: ["我叫王小明", misheard], confirmation: true)
        try await reachQuestion(h)
        try await answer(h, until: .transcriptConfirmation)
        await h.session.leave()
        #expect(h.session.heardTranscript.isEmpty)
        await h.session.confirmTranscript()
        #expect(h.image.calls.current == 0)
        #expect(h.session.turns.isEmpty)
    }

    @Test func oldRecordsWithoutRawTextStillDecode() throws {
        let json = #"{"question":"q","text":"t","kind":"memory","createdAt":0,"imagePath":""}"#
        let turn = try JSONDecoder().decode(ConversationTurn.self, from: Data(json.utf8))
        #expect(turn.rawText == nil)
    }

    // MARK: Typed instead of spoken

    @Test func typedAnswerMakesThePhotoWithoutCorrection() async throws {
        let h = try make(transcripts: ["我叫王小明"], confirmation: true)
        try await reachQuestion(h)
        await h.session.submitTypedText("   ")
        #expect(h.session.stage == .question)
        await h.session.submitTypedText("  我以前在台南織布  ")
        #expect(h.session.stage == .evaluation)
        #expect(h.image.calls.current == 1)
        #expect(h.correctionRequests.current.isEmpty, "打的字不校正")
        #expect(h.session.turns.last?.text == "我以前在台南織布")
        #expect(h.session.turns.last?.kind == .memory)
        #expect(h.session.turns.last?.rawText == nil)
    }

    @Test func typedRevisionRevisesThePhoto() async throws {
        let h = try make(transcripts: ["我叫王小明"], correction: false)
        try await reachQuestion(h)
        await h.session.submitTypedText("我沒有織過布")
        h.session.chooseDislike()
        await h.session.submitTypedText("布要紅色")
        #expect(h.session.stage == .evaluation)
        #expect(h.image.calls.current == 2)
        #expect(h.session.turns.last?.kind == .correction)
        #expect(h.session.turns.last?.text == "布要紅色")
    }

    @Test func typingIsIgnoredWhileRecording() async throws {
        let h = try make(transcripts: ["我叫王小明", misheard], correction: false)
        try await reachQuestion(h)
        await h.session.startAnswerRecording()
        #expect(h.session.isRecording)
        await h.session.submitTypedText("我沒有織過布")
        #expect(h.session.turns.isEmpty)
        #expect(h.image.calls.current == 0)
    }

    // MARK: NCKU Taiwanese → Mandarin

    @Test func nckuTaiwaneseIsTranslatedBeforeThePhoto() async throws {
        let taiwanese = "我細漢定定去溪仔邊掠魚仔"
        let h = try make(transcripts: ["我叫王小明", taiwanese], correction: false,
                         settings: [ConfigKey.speechProvider: "ncku"])
        try await reachQuestion(h)
        try await answer(h, until: .evaluation)
        #expect(h.session.turns.last?.text == "我小時候常常去溪邊抓魚")
        #expect(h.session.turns.last?.rawText == taiwanese)
    }

    @Test func translationOnlyForTheMedicalModelAndWhenOn() throws {
        func config(_ values: [String: String]) throws -> ConfigStore {
            let defaults = UserDefaults(suiteName: "reminicare-tests-\(UUID().uuidString)")!
            for (key, value) in values { defaults.set(value, forKey: key) }
            let config = ConfigStore(defaults: defaults, secrets: MemorySecretStore())
            try config.load()
            return config
        }
        #expect(try config([ConfigKey.speechProvider: "ncku"]).translatesTranscriptToMandarin)
        #expect(try config([ConfigKey.speechProvider: "ncku"]).nckuSttModel == .medical)
        #expect(try !config([ConfigKey.speechProvider: "ncku", ConfigKey.nckuSttModel: NckuSttModel.mixed.rawValue]).translatesTranscriptToMandarin)
        #expect(try !config([ConfigKey.speechProvider: "ncku", ConfigKey.nckuSttToMandarin: "false"]).translatesTranscriptToMandarin)
        #expect(try !config([ConfigKey.speechProvider: "yating"]).translatesTranscriptToMandarin)
    }

    @Test func implausibleTranslationKeepsTheOriginal() async {
        let padded = ReminiscenceAI(client: FakeLlm(#"{"text":"我小時候常常去溪邊抓魚，那時候的溪水很清澈，魚也很多，大家都很開心地一起玩"}"#))
        #expect(await padded.mandarinTranscript("我細漢掠魚仔") == nil)
        let failing = ReminiscenceAI(client: FakeLlm { _ in throw AIServiceError(.network, "offline") })
        #expect(await failing.mandarinTranscript("我細漢掠魚仔") == nil)
        let good = ReminiscenceAI(client: FakeLlm(#"{"text":"我小時候抓魚"}"#))
        #expect(await good.mandarinTranscript("我細漢掠魚仔") == "我小時候抓魚")
    }
}

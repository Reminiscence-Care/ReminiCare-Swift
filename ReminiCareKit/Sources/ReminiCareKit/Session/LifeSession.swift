import Foundation
import Observation

public enum LifeStage: String, Sendable {
    case topicLoading, topicSelection, introduction, question, imageGenerating
    case evaluation, revisionRecording, revisionGenerating, summary
    /// Recognized (and possibly AI-corrected) text waiting for a person to confirm.
    case transcriptConfirmation
}

public enum IntroductionState: Sendable { case ready, recording, processing, confirmed }

/// The reminiscence conversation: topic → introductions → memories → photo → summary.
@MainActor
@Observable
public final class LifeSession {
    public private(set) var stage: LifeStage = .topicLoading
    public private(set) var introductionState: IntroductionState = .ready
    public private(set) var topics: [ReminiscenceTopic] = []
    public private(set) var selectedTopic: ReminiscenceTopic?
    public private(set) var elderNames: [String] = []
    public private(set) var currentElderName = ""
    public private(set) var introductionRevision = 0
    public private(set) var selectedLanguage: SpeechLanguage = .taiwanese
    public private(set) var currentQuestion = ""
    public private(set) var transcript = ""
    public private(set) var keywords: [String] = []
    /// Relative to the documents root (`reminicare_images/...`).
    public private(set) var currentImagePath = ""
    public private(set) var errorMessage: String?
    public private(set) var topicWarning: String?
    public private(set) var audioWarning: String?
    public private(set) var recordSeconds = 0
    public private(set) var isRecording = false
    public private(set) var isTranscribing = false
    public private(set) var transcriptionComplete = 0
    public private(set) var transcriptionTotal = 0
    public private(set) var hasExtension = false
    public private(set) var hasInterruptedRecording = false
    public private(set) var isSaving = false
    public private(set) var isSaved = false
    public private(set) var turns: [ConversationTurn] = []
    /// AI correction of the recognized text is running.
    public private(set) var isCorrecting = false
    /// Text shown on the confirmation screen (after AI correction).
    public private(set) var heardTranscript = ""
    /// Speech-recognition output behind `heardTranscript`.
    public private(set) var rawTranscript = ""
    /// The text being confirmed is a photo-revision request, not a memory.
    public private(set) var confirmingRevision = false

    @ObservationIgnored private let config: ConfigStore
    @ObservationIgnored private let ai: ReminiscenceAI
    @ObservationIgnored private let imageClient: ImageGenerating
    @ObservationIgnored private let recognizer: SpeechRecognizer
    @ObservationIgnored private let memories: MemoryRepository
    @ObservationIgnored private let catalogLoader: () throws -> TopicCatalog
    @ObservationIgnored private let voiceFactory: () -> VoiceIO
    @ObservationIgnored private var voice: VoiceIO?
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var pendingAudio: [URL] = []
    @ObservationIgnored private var lastText = ""
    @ObservationIgnored private var lastWasRevision = false
    @ObservationIgnored private var sessionImages: Set<String> = []
    @ObservationIgnored private var memoryId: String?
    @ObservationIgnored private var transcription: Task<String, Error>?
    @ObservationIgnored private var recordTimer: Task<Void, Never>?
    @ObservationIgnored private var loggedStage: LifeStage?
    @ObservationIgnored private var loggedError: String?
    @ObservationIgnored private var loggedWarning: String?

    public init(
        config: ConfigStore = .shared,
        ai: ReminiscenceAI,
        image: ImageGenerating,
        recognizer: SpeechRecognizer,
        memories: MemoryRepository = MemoryRepository(),
        catalog: @escaping () throws -> TopicCatalog = { try TopicCatalog.load() },
        voice: @escaping () -> VoiceIO
    ) {
        self.config = config
        self.ai = ai
        imageClient = image
        self.recognizer = recognizer
        self.memories = memories
        catalogLoader = catalog
        voiceFactory = voice
    }

    /// Production wiring from the saved settings.
    public static func live(config: ConfigStore = .shared) -> LifeSession {
        let factory = ServiceFactory(config: config)
        let synthesizer = factory.synthesizer()
        let identity = config.ttsCacheIdentity
        return LifeSession(
            config: config, ai: factory.reminiscenceAI(), image: factory.image(), recognizer: factory.recognizer(),
            voice: { VoiceAssistant(synthesizer: synthesizer, identity: identity) }
        )
    }

    public var canEditImage: Bool { imageClient.config.supports(.imageEditing) }
    public var canRetryTranscription: Bool { !pendingAudio.isEmpty && !isTranscribing }
    public static let emptyTranscriptMessage = "沒有辨識到語音。可以按「重試辨識」再送一次，或重新錄音。"
    public var canRetryLastStep: Bool {
        !busy && !lastText.isEmpty && errorMessage != nil && [.introduction, .question, .revisionRecording].contains(stage)
    }
    public var memoryTranscript: String {
        turns.filter { $0.kind == .memory }.map(\.text).joined(separator: "，")
    }
    public var currentImageURL: URL? { memories.imageURL(currentImagePath) }

    /// Topic plus each question and answer, so the scene step reads the
    /// spoken answers in context instead of as one run-on transcript.
    var memoryContext: String {
        let answers = turns.filter { $0.kind == .memory }
        guard !answers.isEmpty else { return "" }
        var lines = selectedTopic.map { ["主題：\($0.title)"] } ?? []
        for turn in answers { lines += ["問：\(turn.question)", "答：\(turn.text)"] }
        return lines.joined(separator: "\n")
    }

    private func isCurrent(_ value: Int) -> Bool { !closed && value == session }

    // MARK: Topics

    public func initialize() async {
        errorMessage = nil
        await refreshTopics()
    }

    public func refreshTopics() async {
        let previous = Set(topics.map(\.topicId))
        session += 1
        let current = session
        stage = .topicLoading
        topics = []
        selectedTopic = nil
        errorMessage = nil
        topicWarning = nil
        changed()
        cleanupStaleRecordings()
        do {
            topics = try catalogLoader().pickFour(excluding: previous)
        } catch {
            AppLog.shared.record(.flow, .failed, detail: "load")
            errorMessage = "初始化失敗，請重試。"
            changed()
            return
        }
        stage = .topicSelection
        changed()
        let original = topics
        do {
            let enriched = try await ai.questions(for: original)
            guard isCurrent(current), stage == .topicSelection else { return }
            topics = enriched
        } catch {
            guard isCurrent(current) else { return }
            AppLog.shared.record(.ai, .warning, detail: "fallbackQuestions")
            topicWarning = "暫時使用預設問題。"
        }
        changed()
    }

    public func selectTopic(_ topic: ReminiscenceTopic) {
        guard stage == .topicSelection else { return }
        introductionRevision += 1
        session += 1
        selectedTopic = topic
        currentQuestion = topic.question
        stage = .introduction
        introductionState = .ready
        changed()
        Task { await play("請大家介紹自己", both: true) }
    }

    // MARK: Introductions

    public func startIntroductionRecording() async {
        guard !closed, stage == .introduction, !busy, introductionState != .recording else { return }
        introductionRevision += 1
        if await startRecording() { introductionState = .recording }
        changed()
    }

    public func stopRecording() async { await voice?.finishRecording() }

    public func addNextParticipant() {
        guard !busy, introductionState == .confirmed, stage == .introduction else { return }
        introductionRevision += 1
        commitCurrentName()
        introductionState = .ready
        changed()
    }

    public func finishIntroduction() async {
        guard !busy, introductionState == .confirmed, stage == .introduction else { return }
        introductionRevision += 1
        commitCurrentName()
        stage = .question
        introductionState = .ready
        changed()
        await play(currentQuestion, both: true)
    }

    private func commitCurrentName() {
        if !currentElderName.isEmpty && currentElderName != "長輩" { elderNames.append(currentElderName) }
        currentElderName = ""
    }

    public func correctParticipantAddress(_ address: ParticipantAddress, revision: Int) {
        guard !busy, !isRecording, [.ready, .confirmed].contains(introductionState), stage == .introduction,
              revision == introductionRevision, address.isValid else { return }
        currentElderName = address.displayName
        introductionState = .confirmed
        errorMessage = nil
        introductionRevision += 1
        changed()
    }

    // MARK: Memories and photos

    public func startAnswerRecording() async {
        guard !busy, stage == .question else { return }
        transcript = ""
        _ = await startRecording()
        changed()
    }

    public func startRevisionRecording() async {
        guard !busy, stage == .revisionRecording else { return }
        transcript = ""
        _ = await startRecording()
        changed()
    }

    public func chooseLike() async {
        guard !busy, stage == .evaluation else { return }
        if hasExtension { return await finishSession() }
        busy = true
        let current = session
        errorMessage = nil
        do {
            let question = try await ai.extendedQuestion(previous: currentQuestion, response: memoryTranscript)
            guard isCurrent(current) else { return }
            currentQuestion = question
        } catch {
            guard isCurrent(current) else { return }
            AppLog.shared.record(.ai, .warning, detail: "fallbackFollowUp")
            currentQuestion = selectedTopic?.followUpQuestion ?? "這張照片還讓您想到什麼往事？"
        }
        hasExtension = true
        busy = false
        stage = .question
        changed()
        await play(currentQuestion, both: true)
    }

    public func chooseDislike() {
        guard !busy, !closed, stage == .evaluation else { return }
        stage = .revisionRecording
        changed()
        Task { await play("哪裡不太像呢？請告訴我想修改的地方。") }
    }

    public func finishSession() async {
        session += 1
        let current = session
        transcription?.cancel()
        busy = true
        isTranscribing = false
        isCorrecting = false
        clearConfirmation()
        await stopAllAudio()
        clearPendingAudio()
        guard isCurrent(current) else { return }
        busy = false
        stage = .summary
        changed()
    }

    public func replayLanguage(_ language: SpeechLanguage) async {
        selectedLanguage = language
        changed()
        await play(spokenText, language: language)
    }

    public func saveMemory() async -> Bool {
        guard !isSaving, !isSaved, stage == .summary else { return isSaved }
        let watch = Stopwatch()
        AppLog.shared.record(.history, .saving)
        isSaving = true
        errorMessage = nil
        changed()
        defer {
            isSaving = false
            changed()
        }
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        let id = memoryId ?? MemoryRepository.newId()
        memoryId = id
        let record = MemoryRecord(
            id: id, date: formatter.string(from: now), topic: selectedTopic?.title ?? "懷舊時光",
            topicId: selectedTopic?.topicId, content: memoryTranscript.isEmpty ? transcript : memoryTranscript,
            elders: elderNames.isEmpty ? "未留名" : elderNames.joined(separator: "、"),
            imagePath: currentImagePath, createdAt: now, keywords: keywords, turns: turns,
            imageVersions: Array(sessionImages)
        )
        do {
            try await memories.save(record)
            isSaved = true
            AppLog.shared.record(.history, .saved, durationMs: watch.milliseconds)
            return true
        } catch {
            AppLog.shared.record(.history, .failed, durationMs: watch.milliseconds, detail: "save")
            errorMessage = "回憶保存失敗，請重試。"
            return false
        }
    }

    /// Leaving discards unsaved session images.
    public func leave() async {
        closed = true
        introductionRevision += 1
        session += 1
        transcription?.cancel()
        busy = false
        isTranscribing = false
        isCorrecting = false
        clearConfirmation()
        await stopAllAudio()
        await voice?.close()
        clearPendingAudio()
        if !isSaved && !sessionImages.isEmpty { await memories.discardImages(Array(sessionImages)) }
    }

    public func interruptAudio() async { await voice?.interrupt() }

    // MARK: Recording and recognition

    private func startRecording() async -> Bool {
        guard !busy, !isTranscribing, !isRecording else { return false }
        busy = true
        let current = session
        defer { if isCurrent(current) { busy = false } }
        clearPendingAudio()
        lastText = ""
        hasInterruptedRecording = false
        audioWarning = nil
        errorMessage = nil
        let voice = ensureVoice()
        voice.stopPlayback()
        await voice.cancelRecording()
        guard isCurrent(current) else { return false }
        let silence = config.silenceSeconds(introduction: stage == .introduction)
        let maximum = config.maxRecordSeconds
        do {
            let started = try await voice.startRecording(silence: .milliseconds(Int(silence * 1000)), maximum: .seconds(maximum))
            guard isCurrent(current), started else { return false }
        } catch {
            guard isCurrent(current) else { return false }
            isRecording = false
            errorMessage = (error as? SttError)?.message ?? "無法啟動麥克風，請重試。"
            changed()
            return false
        }
        isRecording = true
        recordSeconds = 0
        recordTimer?.cancel()
        recordTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRecording, !Task.isCancelled else { return }
                self.recordSeconds += 1
                if self.recordSeconds >= maximum { await self.voice?.finishRecording() }
            }
        }
        return true
    }

    func completeRecording(_ files: [URL]) async {
        guard !busy else { return }
        isRecording = false
        recordTimer?.cancel()
        pendingAudio = files
        if files.isEmpty {
            errorMessage = "錄音未成功儲存，請重新錄音。"
            introductionState = .ready
            changed()
            return
        }
        await retryTranscription()
    }

    public func retryTranscription() async {
        guard !busy, !pendingAudio.isEmpty else { return }
        busy = true
        isTranscribing = true
        errorMessage = nil
        if stage == .introduction { introductionState = .processing }
        changed()
        let current = session
        defer {
            if isCurrent(current) {
                busy = false
                isTranscribing = false
                changed()
            }
        }
        do {
            let text = try await transcribe(pendingAudio)
            guard isCurrent(current) else { return }
            hasInterruptedRecording = false
            audioWarning = nil
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Keep the recording: "重試辨識" can send it again without repeating the answer.
                AppLog.shared.record(.stt, .warning, operationId: session, detail: "emptyTranscript")
                errorMessage = Self.emptyTranscriptMessage
                if stage == .introduction { introductionState = .ready }
                return
            }
            clearPendingAudio()
            lastText = text
            if stage == .introduction {
                // 稱呼不自動改字：姓氏由 elderName 擷取，同音由人確認。
                await confirmName(from: text, session: current)
                return
            }
            let revision = stage == .revisionRecording
            isTranscribing = false
            var heard = text
            if config.transcriptCorrectionEnabled {
                heard = await correctedTranscript(text, revision: revision)
                guard isCurrent(current) else { return }
            }
            if config.transcriptConfirmationEnabled {
                rawTranscript = text
                heardTranscript = heard
                confirmingRevision = revision
                stage = .transcriptConfirmation
                return
            }
            await proceed(with: heard, raw: text, revision: revision, session: current)
        } catch {
            guard isCurrent(current) else { return }
            errorMessage = (error as? SttError)?.message ?? "語音辨識失敗，請重試或重新錄音。"
            if stage == .introduction { introductionState = .ready }
        }
    }

    /// AI-corrected text, or the original whenever correction fails, times out
    /// or rewrites too much. Never shows an error: correction is best effort.
    private func correctedTranscript(_ text: String, revision: Bool) async -> String {
        isCorrecting = true
        changed()
        defer { isCorrecting = false }
        let context = revision
            ? "哪裡不太像呢？請告訴我想修改照片的地方。（先前分享的回憶：\(memoryTranscript)）"
            : currentQuestion
        let operation = session
        switch await ai.correctTranscript(question: context, transcript: text, topic: selectedTopic?.title ?? "") {
        case .corrected(let fixed):
            AppLog.shared.record(.ai, .progress, operationId: operation, detail: "transcriptCorrected")
            AppLog.shared.recordTranscription(fixed, operationId: operation, corrected: true)
            return fixed
        case .unchanged:
            AppLog.shared.record(.ai, .progress, operationId: operation, detail: "transcriptUnchanged")
        case .rejected:
            AppLog.shared.record(.ai, .warning, operationId: operation, detail: "correctionRejected")
        case .timedOut:
            AppLog.shared.record(.ai, .warning, operationId: operation, detail: "correctionTimeout")
        case .failed:
            AppLog.shared.record(.ai, .warning, operationId: operation, detail: "correctionFailed")
        }
        return text
    }

    /// Stores the turn and makes (or revises) the photo.
    private func proceed(with text: String, raw: String, revision: Bool, session current: Int) async {
        lastText = text
        lastWasRevision = revision
        turns.append(ConversationTurn(
            question: currentQuestion, text: text, kind: revision ? .correction : .memory,
            imagePath: currentImagePath, rawText: raw == text ? nil : raw
        ))
        transcript = memoryTranscript
        if revision {
            await reviseImage(session: current, instruction: text)
        } else {
            await createMemoryImage(session: current, text: memoryTranscript)
        }
    }

    // MARK: Transcript confirmation

    /// The shown text is right: continue with it.
    public func confirmTranscript() async {
        await continueConfirmed(heardTranscript, detail: "transcriptConfirmed")
    }

    /// Continue with text corrected by hand. Empty text is ignored.
    public func submitEditedTranscript(_ text: String) async {
        let edited = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.isEmpty else { return }
        await continueConfirmed(edited, detail: edited == heardTranscript ? "transcriptConfirmed" : "transcriptEdited")
    }

    /// The text is wrong: go back and record again.
    public func rerecordTranscript() {
        guard !busy, !closed, stage == .transcriptConfirmation else { return }
        let revision = confirmingRevision
        clearConfirmation()
        AppLog.shared.record(.flow, .progress, operationId: session, detail: "transcriptRerecord")
        stage = revision ? .revisionRecording : .question
        changed()
    }

    private func continueConfirmed(_ text: String, detail: String) async {
        guard !busy, !closed, stage == .transcriptConfirmation, !text.isEmpty else { return }
        busy = true
        let current = session
        defer {
            if isCurrent(current) {
                busy = false
                changed()
            }
        }
        let raw = rawTranscript
        let revision = confirmingRevision
        clearConfirmation()
        AppLog.shared.record(.flow, .progress, operationId: current, detail: detail)
        if detail == "transcriptEdited" { AppLog.shared.recordTranscription(text, operationId: current, corrected: true) }
        await proceed(with: text, raw: raw, revision: revision, session: current)
    }

    /// Typed instead of spoken (fallback when recognition fails): used as is,
    /// without AI correction or the confirmation screen.
    public func submitTypedText(_ text: String) async {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !busy, !closed, !isRecording, !isTranscribing,
              [.question, .revisionRecording].contains(stage) else { return }
        busy = true
        let current = session
        defer {
            if isCurrent(current) {
                busy = false
                changed()
            }
        }
        clearPendingAudio()
        errorMessage = nil
        AppLog.shared.record(.flow, .progress, operationId: current, detail: "typedAnswer")
        AppLog.shared.recordTranscription(typed, operationId: current, corrected: true)
        await proceed(with: typed, raw: typed, revision: stage == .revisionRecording, session: current)
    }

    private func clearConfirmation() {
        heardTranscript = ""
        rawTranscript = ""
        confirmingRevision = false
    }

    private func confirmName(from text: String, session current: Int) async {
        introductionState = .processing
        changed()
        do {
            let name = try await ai.elderName(from: text)
            guard isCurrent(current) else { return }
            currentElderName = name
            introductionState = .confirmed
        } catch {
            guard isCurrent(current) else { return }
            // 姓氏確認不到時，先用聽到的內容稱呼，可再按「修改稱呼」更正。
            let heard = ReminiscenceAI.heardName(text)
            AppLog.shared.record(.ai, .warning, detail: heard.isEmpty ? "noName" : "fallbackName")
            if heard.isEmpty {
                currentElderName = ""
                errorMessage = "沒有確認到您的姓氏，請再介紹一次，並說明希望怎麼稱呼您。"
                introductionState = .ready
            } else {
                currentElderName = heard
                introductionState = .confirmed
            }
        }
        changed()
    }

    private func transcribe(_ files: [URL]) async throws -> String {
        var parts: [String] = []
        for file in files {
            let recognizer = recognizer
            let progress: SttProgress = { [weak self] complete, total in
                Task { @MainActor in
                    guard let self else { return }
                    self.transcriptionComplete = complete
                    self.transcriptionTotal = total
                    AppLog.shared.record(.stt, .progress, complete: complete, total: total)
                }
            }
            let task = Task { try await recognizer.transcribe(file, progress: progress) }
            transcription = task
            let watch = Stopwatch()
            AppLog.shared.record(.stt, .started)
            do {
                let text = try await task.value
                AppLog.shared.record(.stt, .completed, durationMs: watch.milliseconds)
                AppLog.shared.recordTranscription(text, operationId: session)
                if !text.isEmpty { parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            } catch {
                let stt = error as? SttError
                let cancelled = task.isCancelled || stt?.kind == .cancelled
                AppLog.shared.record(.stt, cancelled ? .cancelled : .failed, durationMs: watch.milliseconds, detail: stt?.kind.rawValue ?? "network")
                if let stt, !cancelled, !stt.partialText.isEmpty {
                    AppLog.shared.recordTranscription(stt.partialText, operationId: session, partial: true)
                }
                throw cancelled ? SttError(.cancelled, "已取消辨識。") : (stt ?? SttError(.network, "語音辨識失敗，請重試。"))
            }
        }
        return parts.joined(separator: "，")
    }

    private func clearPendingAudio() {
        transcription?.cancel()
        transcription = nil
        // Kept for a while (not deleted) so a problem report can attach them.
        let files = pendingAudio
        pendingAudio = []
        if !files.isEmpty { Task { for file in files { await RecentRecordings.shared.keep(file) } } }
    }

    private func cleanupStaleRecordings() {
        let directory = FileManager.default.temporaryDirectory
        let deadline = Date().addingTimeInterval(-24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix("reminicare_chat_smart_") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < deadline { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func createMemoryImage(session current: Int, text: String) async {
        stage = .imageGenerating
        errorMessage = nil
        changed()
        let topicPrompt = selectedTopic?.imagePrompt ?? ""
        var scene = text.trimmingCharacters(in: .whitespaces).isEmpty ? topicPrompt : "\(topicPrompt). Personal memory: \(text)"
        var era = "1960s-1980s"
        var location = "Taiwan"
        do {
            let data = try await ai.sceneData(from: text, context: memoryContext)
            guard isCurrent(current) else { return }
            keywords = data.keywords
            if !data.scene.isEmpty { scene = data.scene }
            era = data.era ?? era
            location = data.location ?? location
        } catch {
            guard isCurrent(current) else { return }
            AppLog.shared.record(.ai, .warning, detail: "fallbackKeywords")
            keywords = Array(text.components(separatedBy: CharacterSet(charactersIn: "，。 \n\t")).filter { $0.count >= 2 }.prefix(5))
        }
        do {
            let url = try await imageClient.generate(prompt: NostalgicImagePrompt.build(scene: scene, era: era, location: location))
            let relative = memories.relativePath(url) ?? ""
            guard isCurrent(current) else {
                await memories.discardImages([relative])
                return
            }
            sessionImages.insert(relative)
            currentImagePath = relative
            stage = .evaluation
        } catch {
            guard isCurrent(current) else { return }
            errorMessage = (error as? AIServiceError)?.message ?? "圖片產生失敗，請重試。"
            stage = .question
        }
        changed()
        if stage == .evaluation { Task { await play("這張照片像您的回憶嗎？", both: true) } }
    }

    private func reviseImage(session current: Int, instruction: String) async {
        stage = .revisionGenerating
        errorMessage = nil
        changed()
        do {
            let url: URL
            if canEditImage, let source = currentImageURL {
                url = try await imageClient.edit(
                    image: source,
                    instruction: instruction.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "Make the image better match the speaker’s memory while preserving the people and composition."
                        : instruction
                )
            } else {
                url = try await imageClient.generate(prompt: NostalgicImagePrompt.build(scene: "\(memoryTranscript). Requested correction: \(instruction)"))
            }
            let relative = memories.relativePath(url) ?? ""
            guard isCurrent(current) else {
                await memories.discardImages([relative])
                return
            }
            sessionImages.insert(relative)
            currentImagePath = relative
            stage = .evaluation
        } catch {
            guard isCurrent(current) else { return }
            errorMessage = (error as? AIServiceError)?.message ?? "圖片修改失敗，請重試。"
            stage = .revisionRecording
        }
        busy = false
        changed()
        if stage == .evaluation { Task { await play("這樣像嗎？", both: true) } }
    }

    public func retryLastStep() async {
        guard canRetryLastStep, !closed else { return }
        busy = true
        errorMessage = nil
        let current = session
        defer {
            if isCurrent(current) {
                busy = false
                changed()
            }
        }
        if stage == .introduction {
            await confirmName(from: lastText, session: current)
        } else if lastWasRevision {
            await reviseImage(session: current, instruction: lastText)
        } else {
            await createMemoryImage(session: current, text: memoryTranscript)
        }
    }

    // MARK: Audio

    private var spokenText: String {
        switch stage {
        case .introduction: "請大家介紹自己"
        case .evaluation: hasExtension ? "這樣像嗎？" : "這張照片像您的回憶嗎？"
        case .revisionRecording: "哪裡不太像呢？請告訴我想修改的地方。"
        default: currentQuestion
        }
    }

    private func play(_ text: String, language: SpeechLanguage? = nil, both: Bool = false) async {
        guard !text.isEmpty, !closed else { return }
        let current = session
        let outcome = await ensureVoice().play([text], languages: both ? [.taiwanese, .mandarin] : [language ?? selectedLanguage])
        if isCurrent(current) && outcome == .failed {
            audioWarning = "語音播放失敗，可以點選語言重播，或直接開始錄音。"
            changed()
        }
    }

    private func ensureVoice() -> VoiceIO {
        if let voice { return voice }
        let created = voiceFactory()
        created.onPlayingLanguageChanged = { [weak self] language in
            self?.selectedLanguage = language
        }
        created.onSpeechCompleted = { [weak self] files in
            Task { await self?.completeRecording(files) }
        }
        created.onWarning = { [weak self] message in
            self?.audioWarning = message
            self?.changed()
        }
        created.onRecordingFailed = { [weak self] in
            guard let self else { return }
            self.isRecording = false
            self.recordTimer?.cancel()
            self.errorMessage = "錄音操作失敗，請重新錄音。"
            self.introductionState = .ready
            self.changed()
        }
        created.onInterrupted = { [weak self] files in
            guard let self else { return }
            self.isRecording = false
            self.recordTimer?.cancel()
            self.pendingAudio = files
            self.hasInterruptedRecording = !files.isEmpty
            self.introductionState = .ready
            self.audioWarning = "錄音已中斷，已保留可用音檔；可以辨識或重新錄音。"
            self.changed()
        }
        voice = created
        return created
    }

    private func stopAllAudio() async {
        recordTimer?.cancel()
        isRecording = false
        voice?.stopPlayback()
        await voice?.cancelRecording()
    }

    /// Logs stage changes, new errors and warnings.
    private func changed() {
        if stage != loggedStage {
            loggedStage = stage
            AppLog.shared.record(.flow, .stageChanged, operationId: session, detail: stage.rawValue)
        }
        if errorMessage != loggedError {
            loggedError = errorMessage
            if errorMessage != nil { AppLog.shared.record(.flow, .failed, operationId: session, detail: stage.rawValue) }
        }
        if audioWarning != loggedWarning {
            loggedWarning = audioWarning
            if audioWarning != nil { AppLog.shared.record(.flow, .warning, operationId: session) }
        }
    }
}

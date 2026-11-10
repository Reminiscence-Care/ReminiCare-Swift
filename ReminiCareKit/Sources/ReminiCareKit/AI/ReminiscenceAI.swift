import Foundation

public struct SceneData: Sendable {
    public var scene: String
    public var era: String?
    public var location: String?
    public var keywords: [String]
}

/// Prompts and validation for the reminiscence flow.
public struct ReminiscenceAI: Sendable {
    public let client: LlmClient
    public init(client: LlmClient) { self.client = client }

    /// Some models (e.g. Qwen on Groq) slip into Simplified Chinese despite the
    /// prompt. ICU's Hans-Hant converts only simplified characters and leaves
    /// Traditional text (台, 裡, 後…) as it is.
    static func traditional(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    /// One LLM call tagged with its purpose in the App Log, so a failure line
    /// says which step failed (the client logs the HTTP status and error kind).
    private func ask(
        _ purpose: String, _ messages: [LlmMessage], temperature: Double = 0.6, maxTokens: Int, jsonObject: Bool = false
    ) async throws -> String {
        let watch = Stopwatch()
        AppLog.shared.record(.ai, .started, detail: purpose)
        do {
            let reply = try await client.complete(messages, temperature: temperature, maxTokens: maxTokens, jsonObject: jsonObject)
            AppLog.shared.record(.ai, .completed, durationMs: watch.milliseconds, detail: purpose)
            return Self.traditional(reply)
        } catch {
            AppLog.shared.record(
                .ai, isCancellation(error) ? .cancelled : .failed, durationMs: watch.milliseconds,
                statusCode: (error as? AIServiceError)?.statusCode, detail: purpose
            )
            throw error
        }
    }

    /// Generates a main and follow-up question for each fixed catalog topic.
    public func questions(for topics: [ReminiscenceTopic]) async throws -> [ReminiscenceTopic] {
        let list = topics.map { ["topicId": $0.topicId, "title": $0.title] }
        let json = String(data: try JSONSerialization.data(withJSONObject: list), encoding: .utf8) ?? "[]"
        let raw = try await ask("questions", [
            LlmMessage("system", "你是台灣長輩回憶聊天引導員，只輸出合法 JSON。"),
            LlmMessage("user", "為以下固定主題各產生一個親切主問題與延伸問題。不得改變 topicId 或主題。回傳 {\"topics\":[{\"topicId\":\"...\",\"question\":\"...\",\"followUpQuestion\":\"...\"}]}。主題：\(json)"),
        ], maxTokens: 1200, jsonObject: true)
        let data = try ProviderResponseParser.decodeJSONObject(raw, requiredKey: "topics")
        guard let rows = data["topics"] as? [[String: Any]], rows.count == topics.count else {
            throw AIServiceError(.invalidResponse, "四主題問題不完整")
        }
        var byId: [String: [String: Any]] = [:]
        for row in rows { if let id = row["topicId"] as? String { byId[id] = row } }
        return try topics.map { topic in
            guard let row = byId[topic.topicId],
                  let question = (row["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty,
                  let followUp = (row["followUpQuestion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !followUp.isEmpty
            else { throw AIServiceError(.invalidResponse, "主題 ID 或問題錯誤") }
            var copy = topic
            copy.question = question
            copy.followUpQuestion = followUp
            return copy
        }
    }

    static let compoundSurnames: Set<String> = [
        "歐陽", "欧阳", "司馬", "司马", "上官", "諸葛", "诸葛", "司徒", "司空", "夏侯", "皇甫", "尉遲", "尉迟",
        "公孫", "公孙", "慕容", "令狐", "宇文", "南宮", "南宫", "東方", "东方", "西門", "西门", "獨孤", "独孤",
        "長孫", "长孙", "端木", "赫連", "赫连", "澹臺", "澹台", "太史", "聞人", "闻人", "申屠", "公羊", "仲孫",
        "仲孙", "軒轅", "轩辕", "太叔", "淳于", "公冶", "子車", "子车", "顓孫", "颛孙",
    ]
    static let titles: Set<String> = ["先生", "小姐", "女士", "阿公", "阿嬤", "伯伯", "阿姨", "爺爺", "奶奶", "哥哥", "姊姊", "長輩"]
    /// 語音辨識常把台語稱謂寫成同音字。
    static let titleVariants: [String: [String]] = [
        "阿嬤": ["阿媽", "阿罵", "阿麼", "阿嬷"],
        "姊姊": ["姐姐"],
        "伯伯": ["阿伯"],
        "奶奶": ["嬭嬭"],
    ]

    /// Surname plus the speaker's own title. The surname must appear in the
    /// transcript; an unclear title falls back to 長輩.
    public func elderName(from transcript: String) async throws -> String {
        let result = try await ask("elderName", [
            LlmMessage("system",
                "從自我介紹只擷取正在說話者的姓氏及本人明確指定的稱謂，不擷取名字或其他人的姓氏。"
                + "只輸出 JSON，例如 {\"surname\":\"王\",\"title\":\"先生\"}；未知值使用 JSON null，不是字串。"
                + "surname 只包含姓氏，通常一個中文字，歐陽、司馬等複姓保留兩字；"
                + "例如王鴻、王泓皆回傳王，歐陽鴻回傳歐陽。必須出現在逐字稿內；不確定姓氏填 null。"
                + "title 僅能是先生、小姐、女士、阿公、阿嬤、伯伯、阿姨、爺爺、奶奶、哥哥、姊姊、長輩，"
                + "且必須是本人在逐字稿明確指定的稱呼；未指定填 null，不要依名字猜性別。"
                + "逐字稿來自語音辨識，稱謂可能是同音字（如阿媽、阿罵寫成阿嬤，姐姐寫成姊姊，阿伯寫成伯伯），請輸出正規稱謂。"),
            LlmMessage("user", transcript),
        ], temperature: 0.1, maxTokens: 1024, jsonObject: true)
        return try Self.validateName(result, transcript: transcript)
    }

    static func validateName(_ result: String, transcript: String) throws -> String {
        let failure = AIServiceError(.invalidResponse, "沒有確認到您的姓氏，請再介紹一次，例如「我姓王，請叫我王先生」。")
        guard let data = try? ProviderResponseParser.decodeJSONObject(result, requiredKey: "surname") else { throw failure }
        func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        let spoken = compact(transcript)
        guard let raw = data["surname"] as? String else { throw failure }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.range(of: #"^[\x{3400}-\x{9FFF}]{1,2}$"#, options: .regularExpression) != nil,
              name.count == 1 || compoundSurnames.contains(name),
              spoken.contains(compact(name)),
              !titles.contains(where: { name.hasSuffix($0) })
        else { throw failure }
        var confirmedTitle = "長輩"
        if let title = data["title"] as? String, titles.contains(title),
           ([title] + (titleVariants[title] ?? [])).contains(where: { spoken.contains($0) }) {
            confirmedTitle = title
        }
        return name + confirmedTitle
    }

    /// 從自我介紹逐字稿去掉「我叫」「叫做」等開頭，留下聽到的名字（最多 6 字）。
    public static func heardName(_ transcript: String) -> String {
        var text = transcript.replacingOccurrences(of: #"[\s，,。.!！?？、：:；;「」『』"（）()]"#, with: "", options: .regularExpression)
        let prefix = #"^(大家好|你好|您好|我的名字是|我的名字叫|請叫我|我叫做|叫我|我叫|叫做|我是|我姓|名字是|姓)"#
        while let range = text.range(of: prefix, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return String(text.prefix(6))
    }

    public func extendedQuestion(previous: String, response: String) async throws -> String {
        try await ask("followUp", [
            LlmMessage("system", "你是親切的台灣回憶治療引導員。根據回答提出一個具體、溫暖、25到45字的繁體中文延伸問題，只回傳問題。"),
            LlmMessage("user", "先前問題：\(previous)\n長輩回答：\(response)"),
        ], temperature: 0.75, maxTokens: 100)
    }

    // MARK: Transcript correction

    public enum CorrectionOutcome: Sendable, Equatable {
        case corrected(String), unchanged, rejected, timedOut, failed
    }

    public static let correctionTimeout: Duration = .seconds(20)

    /// Fixes obvious speech-recognition errors (homophones, near-sounding
    /// words, broken phrases) using the question as context. Never throws:
    /// any failure, timeout or implausible rewrite means "keep the original".
    public func correctTranscript(
        question: String, transcript: String, topic: String = "", timeout: Duration = correctionTimeout
    ) async -> CorrectionOutcome {
        let topicLine = topic.isEmpty ? "" : "聊天主題：\(topic)\n"
        let messages = [
            LlmMessage("system",
                "你是語音辨識校對員。逐字稿是台灣長輩用國語或台語口語回答問題，經語音辨識後常有同音字、近音字或斷句錯誤。"
                + "台灣口音常把 zh/ch/sh 念成 z/c/s、n 念成 l、ing 念成 in、eng 念成 en，所以「織」可能被辨識成「字」「吃」「知」，"
                + "「布」被切成獨立的「不」並多出逗號。"
                + "校正步驟：一、找出在主題與問題脈絡下說不通的字詞；二、只換成讀音相同或非常相近（拼音相同或只差聲調、口音）的字詞，"
                + "優先選主題與問題裡出現過的詞；三、讀音不相近的不要換，看不出原意就保留原文。"
                + "範例（主題：織布）：「我沒有吃過，不」→「我沒有織過布」；「我沒有字過，不」→「我沒有織過布」；"
                + "「我們都是去，不」若說的是織布，→「我們都是去織布」。"
                + "不得新增或刪除內容，不得改寫、潤飾、摘要或回答問題，保留口語用詞與語氣。"
                + "只輸出 JSON：{\"changes\":[{\"from\":\"原文片段\",\"to\":\"改成\",\"pinyin\":\"原文拼音 → 改後拼音\"}],\"text\":\"校正後的完整逐字稿\"}；"
                + "沒有要改就輸出 {\"changes\":[],\"text\":\"原文\"}。"),
            LlmMessage("user", "\(topicLine)問題：\(question)\n逐字稿：\(transcript)"),
        ]
        let raw: String?
        do {
            raw = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    try await self.ask("transcriptCorrection", messages, temperature: 0.1, maxTokens: 1024, jsonObject: true)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        } catch {
            return .failed
        }
        guard let raw else { return .timedOut }
        guard let text = Self.validateCorrection(raw, original: transcript, question: question) else { return .rejected }
        return text == transcript.trimmingCharacters(in: .whitespacesAndNewlines) ? .unchanged : .corrected(text)
    }

    /// Taiwanese Hanzi from NCKU's medical model, in Mandarin; nil on failure,
    /// timeout or an implausible reply (the caller keeps the original).
    public func mandarinTranscript(_ transcript: String, timeout: Duration = correctionTimeout) async -> String? {
        let messages = [
            LlmMessage("system",
                "你是台語翻譯。逐字稿是台灣長輩回答問題的語音辨識結果，台語部分以台語漢字書寫（例如「佇」「細漢」「食飽未」），也可能夾雜華語。"
                + "把它翻成自然的台灣華語（繁體中文），意思不可增減，不要潤飾、摘要或回答問題；已經是華語的部分保持原樣；人名、地名照寫。"
                + "只輸出 JSON：{\"text\":\"翻譯後的完整逐字稿\"}。"),
            LlmMessage("user", transcript),
        ]
        do {
            let raw = try await withTimeout(timeout) {
                try await self.ask("transcriptTranslation", messages, temperature: 0.1, maxTokens: 1024, jsonObject: true)
            }
            guard let data = try? ProviderResponseParser.decodeJSONObject(raw, requiredKey: "text"),
                  let text = (data["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            // A translation stays about as long as what was said; much longer means it added content.
            let before = transcript.filter { $0.isLetter || $0.isNumber }.count
            let after = text.filter { $0.isLetter || $0.isNumber }.count
            return after <= max(before * 2, before + 8) ? text : nil
        } catch {
            return nil
        }
    }

    /// The corrected text, or nil when the reply is unusable or rewrites too
    /// much to be a recognition fix.
    static func validateCorrection(_ raw: String, original: String, question: String) -> String? {
        guard let data = try? ProviderResponseParser.decodeJSONObject(raw, requiredKey: "text"),
              let text = (data["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        func core(_ value: String) -> Int { value.filter { $0.isLetter || $0.isNumber }.count }
        let before = core(original)
        guard abs(core(text) - before) <= max(4, before * 3 / 10) else { return nil }
        let source = original + question
        for run in asciiRuns(text) where !source.contains(run) { return nil }
        // Each listed change must replace something actually said with a
        // similar-length phrase; anything else is a rewrite, not a fix.
        let compactOriginal = original.filter { $0.isLetter || $0.isNumber }
        for change in data["changes"] as? [[String: Any]] ?? [] {
            let from = (change["from"] as? String ?? "").filter { $0.isLetter || $0.isNumber }
            let to = (change["to"] as? String ?? "").filter { $0.isLetter || $0.isNumber }
            guard !from.isEmpty, compactOriginal.contains(from), abs(from.count - to.count) <= 1 else { return nil }
        }
        return text
    }

    /// Runs of ASCII letters and digits, e.g. names or numbers the model may invent.
    private static func asciiRuns(_ text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.isASCII && (character.isLetter || character.isNumber) {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Turns the spoken answers into one coherent scene for the image prompt.
    /// `context` holds the topic and each question with its answer, so
    /// fragments and leftover recognition errors are read in context.
    public func sceneData(from transcript: String, context: String = "") async throws -> SceneData {
        let raw = try await ask("sceneData", [
            LlmMessage("system",
                "你協助把台灣長輩口述的回憶變成一張照片的畫面描述。回答是語音辨識的口語逐字稿，可能有贅字、斷句不完整或殘留的同音錯字，"
                + "請依主題與問題理解原意後再整理，不要照字面翻譯不通順的片段，也不要加入長輩沒提到的人物或事件。"
                + "長輩說「沒有」做過的事，不要畫成他在做；改畫他提到的相關經驗，或在旁觀看的情境。"
                + "只輸出 JSON，只能包含 scene、era、location、keywords："
                + "scene 是一段通順、具體的英文畫面描述（人物、動作、地點、物品），era 例如 \"1970s\"，location 例如 \"rural Tainan, Taiwan\"，未知填 null；"
                + "keywords 是 3 到 6 個繁體中文關鍵詞陣列。"),
            LlmMessage("user", context.isEmpty ? transcript : "\(context)\n\n整理以上回答。"),
        ], temperature: 0.1, maxTokens: 1024, jsonObject: true)
        let data = try ProviderResponseParser.decodeJSONObject(raw, requiredKey: "scene")
        func nonEmpty(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        return SceneData(
            scene: data["scene"].map { "\($0)" } ?? "",
            era: nonEmpty(data["era"]),
            location: nonEmpty(data["location"]),
            keywords: (data["keywords"] as? [Any] ?? []).map { "\($0)" }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        )
    }
}

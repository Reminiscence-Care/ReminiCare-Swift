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

    /// Generates a main and follow-up question for each fixed catalog topic.
    public func questions(for topics: [ReminiscenceTopic]) async throws -> [ReminiscenceTopic] {
        let list = topics.map { ["topicId": $0.topicId, "title": $0.title] }
        let json = String(data: try JSONSerialization.data(withJSONObject: list), encoding: .utf8) ?? "[]"
        let raw = try await client.complete([
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
        let result = try await client.complete([
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
        try await client.complete([
            LlmMessage("system", "你是親切的台灣回憶治療引導員。根據回答提出一個具體、溫暖、25到45字的繁體中文延伸問題，只回傳問題。"),
            LlmMessage("user", "先前問題：\(previous)\n長輩回答：\(response)"),
        ], temperature: 0.75, maxTokens: 100)
    }

    public func sceneData(from transcript: String) async throws -> SceneData {
        let raw = try await client.complete([
            LlmMessage("system", "把回憶整理成 JSON，只能包含 scene、era、location、keywords；keywords 是繁體中文陣列。"),
            LlmMessage("user", transcript),
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

import Foundation

public struct TopicAttribution: Codable, Sendable, Hashable {
    public var title: String
    public var creator: String
    public var source: String
    public var license: String
    public var originalUrl: String
    public var licenseUrl: String
}

public struct ReminiscenceTopic: Sendable, Hashable, Identifiable {
    public var topicId: String
    public var title: String
    public var question: String
    public var followUpQuestion: String
    public var imagePrompt: String
    public var illustrative: Bool
    /// Resource name of the bundled thumbnail, e.g. `grocery.jpg`.
    public var imageName: String
    public var attribution: TopicAttribution?
    public var id: String { topicId }

    public init(
        topicId: String, title: String, question: String, followUpQuestion: String,
        imagePrompt: String, illustrative: Bool = false, imageName: String = "",
        attribution: TopicAttribution? = nil
    ) {
        self.topicId = topicId
        self.title = title
        self.question = question
        self.followUpQuestion = followUpQuestion
        self.imagePrompt = imagePrompt
        self.illustrative = illustrative
        self.imageName = imageName
        self.attribution = attribution
    }

    /// Bundled thumbnail file URL, if present.
    public var imageURL: URL? {
        guard !imageName.isEmpty else { return nil }
        let name = (imageName as NSString).deletingPathExtension
        let ext = (imageName as NSString).pathExtension
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Topics")
    }
}

/// Images bundled with the package, so the app needs no asset catalog
/// (asset catalogs can only be compiled on macOS).
public enum BundledImage {
    public static var home: URL? { Bundle.module.url(forResource: "HomeImage", withExtension: "png") }
}

public struct TopicCatalog: Sendable {
    public let topics: [ReminiscenceTopic]
    public init(topics: [ReminiscenceTopic]) { self.topics = topics }

    private struct Row: Decodable {
        let topicId: String
        let title: String
        let question: String
        let followUpQuestion: String
        let imagePrompt: String
        let assetPath: String
        let illustrative: Bool?
        let attribution: TopicAttribution?
    }

    public static func load(bundle: Bundle? = nil) throws -> TopicCatalog {
        let bundle = bundle ?? .module
        guard let url = bundle.url(forResource: "catalog", withExtension: "json", subdirectory: "Topics") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
        return TopicCatalog(topics: rows.map {
            ReminiscenceTopic(
                topicId: $0.topicId, title: $0.title, question: $0.question,
                followUpQuestion: $0.followUpQuestion, imagePrompt: $0.imagePrompt,
                illustrative: $0.illustrative ?? false,
                imageName: ($0.assetPath as NSString).lastPathComponent,
                attribution: $0.attribution
            )
        })
    }

    /// Four topics, preferring ones not shown last time.
    public func pickFour(excluding: Set<String> = []) -> [ReminiscenceTopic] {
        let preferred = topics.filter { !excluding.contains($0.topicId) }.shuffled()
        let others = topics.filter { excluding.contains($0.topicId) }.shuffled()
        return Array((preferred + others).prefix(4))
    }
}

public enum ConversationTurnKind: String, Codable, Sendable { case memory, correction }

public struct ConversationTurn: Codable, Sendable, Hashable {
    public var question: String
    public var text: String
    public var kind: ConversationTurnKind
    public var createdAt: Date
    public var imagePath: String

    public init(question: String, text: String, kind: ConversationTurnKind, createdAt: Date = Date(), imagePath: String = "") {
        self.question = question
        self.text = text
        self.kind = kind
        self.createdAt = createdAt
        self.imagePath = imagePath
    }
}

/// Local correction options, never an automatic spelling replacement.
public struct ParticipantAddress: Sendable, Hashable {
    public var surname: String
    public var title: String
    public init(_ surname: String, _ title: String) {
        self.surname = surname
        self.title = title
    }

    public var displayName: String { surname + title }

    public static let titles = ["先生", "小姐", "女士", "長輩", "阿公", "阿嬤", "伯伯", "阿姨", "爺爺", "奶奶", "哥哥", "姊姊"]
    private static let similarGroups = [["余", "于", "俞", "於"], ["鍾", "鐘"], ["張", "章"], ["江", "姜"], ["楊", "陽"], ["蕭", "肖"], ["梁", "良"]]
    public static let commonSurnames = [
        "陳", "林", "黃", "張", "李", "王", "吳", "劉", "蔡", "楊", "許", "鄭", "謝", "郭", "洪", "邱", "曾", "廖", "賴", "徐",
        "周", "葉", "蘇", "莊", "呂", "江", "何", "蕭", "羅", "高", "余", "于", "俞", "於", "丁", "歐陽", "司馬", "上官", "諸葛",
    ]

    public static func fromDisplayName(_ text: String) -> ParticipantAddress {
        for title in titles where text.hasSuffix(title) {
            return ParticipantAddress(String(text.dropLast(title.count)), title)
        }
        return ParticipantAddress(text, "長輩")
    }

    public static func candidates(for surname: String) -> [String] {
        var result = [surname]
        for group in similarGroups where group.contains(surname) {
            for item in group where !result.contains(item) { result.append(item) }
        }
        return result.filter { !$0.isEmpty }
    }

    /// Manual confirmation permits rare surnames not present in the helper table.
    public var isValid: Bool {
        surname.range(of: #"^[\x{3400}-\x{9FFF}]{1,4}$"#, options: .regularExpression) != nil
            && !Self.titles.contains(where: { surname.hasSuffix($0) })
            && Self.titles.contains(title)
    }
}

public enum SpeechLanguage: String, Sendable, CaseIterable, Codable {
    case taiwanese = "台語"
    case mandarin = "中文"
    var logCode: String { self == .taiwanese ? "tw" : "zh" }
}

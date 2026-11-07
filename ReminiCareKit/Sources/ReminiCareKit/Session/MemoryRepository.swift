import Foundation

public struct MemoryRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var schemaVersion = 2
    public var date: String
    public var topic: String
    public var topicId: String?
    public var content: String
    public var elders: String
    /// Relative to the documents root, e.g. `reminicare_images/x.png`.
    public var imagePath: String
    public var createdAt: Date
    public var keywords: [String]
    public var turns: [ConversationTurn]
    public var imageVersions: [String]
}

/// One JSON file per memory; unreadable files do not hide valid ones.
public actor MemoryRepository {
    public let root: URL
    public init(root: URL = URL.documentsDirectory) { self.root = root }

    private nonisolated var records: URL { root.appending(path: "reminicare_memories", directoryHint: .isDirectory) }
    private nonisolated var images: URL { root.appending(path: "reminicare_images", directoryHint: .isDirectory) }

    public nonisolated static func newId() -> String {
        "\(Int(Date().timeIntervalSince1970 * 1_000_000))-\(String(UInt32.random(in: .min ... .max), radix: 16))"
    }

    /// Absolute URL for a stored relative image path.
    public nonisolated func imageURL(_ relative: String) -> URL? {
        guard relative.hasPrefix("reminicare_images/"), !relative.contains("..") else { return nil }
        return root.appending(path: relative)
    }

    /// Relative path for an image inside the repository's image directory.
    public nonisolated func relativePath(_ url: URL) -> String? {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        guard parent == images.standardizedFileURL.path else { return nil }
        return "reminicare_images/\(url.lastPathComponent)"
    }

    public func load() throws -> [MemoryRecord] {
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        return read()
    }

    private func read() -> [MemoryRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(MemoryRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Idempotent: a stable ID is written once.
    public func save(_ record: MemoryRecord) throws {
        guard record.id.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let target = records.appending(path: "\(record.id).json")
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: target, options: .atomic)
    }

    public func delete(_ id: String) throws {
        guard id.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil,
              let record = read().first(where: { $0.id == id }) else { return }
        try FileManager.default.removeItem(at: records.appending(path: "\(id).json"))
        discard(Set(Self.images(of: record)))
    }

    /// Deletes session images that no saved memory references.
    public func discardImages(_ paths: [String]) {
        discard(Set(paths))
    }

    private func discard(_ paths: Set<String>) {
        let used = Set(read().flatMap(Self.images(of:)))
        for path in paths where !path.isEmpty && !used.contains(path) {
            guard let url = imageURL(path) else { continue }
            // Never delete a file outside this repository's image directory.
            guard url.deletingLastPathComponent().standardizedFileURL.path == images.standardizedFileURL.path else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func images(of record: MemoryRecord) -> [String] {
        [record.imagePath] + record.imageVersions + record.turns.map(\.imagePath)
    }
}

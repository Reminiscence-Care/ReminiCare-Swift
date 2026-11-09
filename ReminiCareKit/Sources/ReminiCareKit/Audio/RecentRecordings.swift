import Foundation

/// The last few conversation recordings, kept for a day so a problem report
/// can attach them (the developer can then run recognition on the same audio).
public actor RecentRecordings {
    public static let shared = RecentRecordings()
    public static let limit = 5
    public static let maxAge: TimeInterval = 24 * 3600

    public let directory: URL
    private let now: @Sendable () -> Date

    public init(directory: URL? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory ?? FileManager.default.temporaryDirectory.appending(path: "reminicare_recent")
        self.now = now
    }

    /// Moves `file` in (named by the time, to match the App Log) and prunes.
    public func keep(_ file: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return }
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now())
        var target = directory.appending(path: "\(stamp).wav")
        var suffix = 1
        while manager.fileExists(atPath: target.path) {
            suffix += 1
            target = directory.appending(path: "\(stamp)-\(suffix).wav")
        }
        do {
            try manager.moveItem(at: file, to: target)
            try? manager.setAttributes([.modificationDate: now()], ofItemAtPath: target.path)
        } catch {
            try? manager.removeItem(at: file)
        }
        prune()
    }

    /// Newest first.
    public func files() -> [URL] {
        prune()
        return sorted()
    }

    private func sorted() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files.filter { $0.pathExtension == "wav" }
            .map { ($0, modified($0)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private func prune() {
        let deadline = now().addingTimeInterval(-Self.maxAge)
        for (index, file) in sorted().enumerated() where index >= Self.limit || modified(file) < deadline {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

import Foundation

public struct TtsCacheEntry: Codable, Sendable, Identifiable, Hashable {
    public var key: String
    public var file: String
    public var size: Int
    public var lastUsed: Date
    public var language: SpeechLanguage
    public var text: String
    public var provider: String
    public var id: String { key }
}

/// Disk cache of synthesized speech keyed by (provider identity, language, text).
public actor TtsCache {
    public static let maximumBytes = 100 * 1024 * 1024
    /// Above NckuSpeechSynthesizer's 140 s fallback budget.
    public static let generateTimeout: Duration = .seconds(150)

    public let directory: URL
    private var pending: [String: Task<URL?, Never>] = [:]

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "tts_cache", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private var indexURL: URL { directory.appending(path: "index.json") }

    public static func key(identity: String, language: SpeechLanguage, text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [identity, language.rawValue, text])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public func entries() -> [TtsCacheEntry] {
        readIndex().values
            .filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
            .sorted { $0.lastUsed > $1.lastUsed }
    }

    public func url(for entry: TtsCacheEntry) -> URL { directory.appending(path: entry.file) }

    public func resolve(_ text: String, language: SpeechLanguage, identity: String, synthesizer: SpeechSynthesizer) async -> URL? {
        let key = Self.key(identity: identity, language: language, text: text)
        if let task = pending[key] { return await task.value }
        let task = Task { await self.load(key: key, text: text, language: language, identity: identity, synthesizer: synthesizer) }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        return result
    }

    private func load(key: String, text: String, language: SpeechLanguage, identity: String, synthesizer: SpeechSynthesizer) async -> URL? {
        var index = readIndex()
        if var entry = index[key], FileManager.default.fileExists(atPath: url(for: entry).path) {
            entry.lastUsed = Date()
            index[key] = entry
            writeIndex(index)
            AppLog.shared.record(.tts, .cacheHit, detail: language.logCode)
            return url(for: entry)
        }
        let audio: Data?
        do {
            audio = try await withTimeout(Self.generateTimeout) { await synthesizer.synthesize(text, language: language) }
        } catch {
            AppLog.shared.record(.tts, .failed, detail: logDetail(error))
            return nil
        }
        guard let audio, !audio.isEmpty, audio.count <= Self.maximumBytes else {
            if let audio { AppLog.shared.record(.tts, .failed, bytes: audio.count, detail: "invalidResponse") }
            return nil
        }
        return store(audio, key: key, text: text, language: language, identity: identity)
    }

    /// Re-synthesizes one entry in place.
    public func regenerate(_ entry: TtsCacheEntry, synthesizer: SpeechSynthesizer) async -> Bool {
        guard let audio = await synthesizer.synthesize(entry.text, language: entry.language), !audio.isEmpty else { return false }
        remove(entry.key)
        return store(audio, key: entry.key, text: entry.text, language: entry.language, identity: entry.provider) != nil
    }

    public func remove(_ key: String) {
        var index = readIndex()
        if let entry = index.removeValue(forKey: key) { try? FileManager.default.removeItem(at: url(for: entry)) }
        writeIndex(index)
    }

    public func clear() {
        for entry in readIndex().values { try? FileManager.default.removeItem(at: url(for: entry)) }
        writeIndex([:])
        AppLog.shared.record(.cache, .cleared)
    }

    private func store(_ audio: Data, key: String, text: String, language: SpeechLanguage, identity: String) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "tts_\(Int(Date().timeIntervalSince1970 * 1_000_000)).wav"
            let file = directory.appending(path: name)
            try audio.write(to: file, options: .atomic)
            var index = readIndex()
            index[key] = TtsCacheEntry(key: key, file: name, size: audio.count, lastUsed: Date(), language: language, text: text, provider: identity)
            var size = index.values.reduce(0) { $0 + $1.size }
            for old in index.values.filter({ $0.key != key }).sorted(by: { $0.lastUsed < $1.lastUsed }) where size > Self.maximumBytes {
                index[old.key] = nil
                size -= old.size
                // Only cache-owned files in this directory may be removed.
                if old.file.hasPrefix("tts_"), !old.file.contains("/") { try? FileManager.default.removeItem(at: url(for: old)) }
            }
            writeIndex(index)
            return file
        } catch {
            AppLog.shared.record(.cache, .failed, detail: "save")
            return nil
        }
    }

    private func readIndex() -> [String: TtsCacheEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let rows = try? JSONDecoder().decode([TtsCacheEntry].self, from: data) else { return [:] }
        return Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
    }

    private func writeIndex(_ index: [String: TtsCacheEntry]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(index.values)) { try? data.write(to: indexURL, options: .atomic) }
    }
}

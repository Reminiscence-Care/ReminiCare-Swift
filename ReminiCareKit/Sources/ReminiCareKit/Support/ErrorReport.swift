import Foundation

/// One problem report: what the user said happened, the App Log and a
/// settings summary. Never holds an API key or token; recordings, when the
/// user leaves them on, are uploaded separately after the issue exists.
public struct ErrorReport: Codable, Sendable, Equatable, Identifiable {
    public var reportId: String
    public var createdAt: String
    public var appVersion: String
    public var appBuild: String
    /// Git commit the app was built from; nil when the build did not stamp one.
    public var appCommit: String?
    public var deviceModel: String
    public var osVersion: String
    public var description: String
    public var includesTranscripts: Bool
    /// How many recordings will follow; nil in reports saved by older builds.
    public var audioCount: Int?
    public var settings: [String: String]
    public var log: String
    public var id: String { reportId }
}

/// App version and device, read once from the running app.
public struct ReportEnvironment: Sendable {
    public var appVersion: String
    public var appBuild: String
    public var appCommit: String?
    public var deviceModel: String
    public var osVersion: String

    public init(appVersion: String, appBuild: String, appCommit: String? = nil, deviceModel: String, osVersion: String) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.appCommit = Self.commit(appCommit)
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }

    /// A short commit like `4fb9d35` or `4fb9d35-dirty`; anything else
    /// (unset, an unexpanded `$(REMINICARE_COMMIT)`) means unknown.
    static func commit(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: #"^[0-9a-f]{7,40}(-dirty)?$"#, options: .regularExpression) != nil
        else { return nil }
        return value
    }

    public static var current: ReportEnvironment {
        let info = Bundle.main.infoDictionary ?? [:]
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return ReportEnvironment(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info["CFBundleVersion"] as? String ?? "?",
            appCommit: info["ReminiCareCommit"] as? String,
            deviceModel: machine.isEmpty ? "?" : machine,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

public enum ErrorReportBuilder {
    public static let maxDescription = 2_000
    public static let maxLogCharacters = 400_000

    /// `entries` is the log as it was when the report screen opened.
    public static func make(
        description: String, includeTranscripts: Bool, audioCount: Int = 0, entries: [AppLogEntry], config: ConfigStore,
        environment: ReportEnvironment = .current, id: UUID = UUID(), now: Date = Date()
    ) -> ErrorReport {
        var log = entries.map { $0.reportLine(includeTranscript: includeTranscripts) }.joined(separator: "\n")
        if log.count > maxLogCharacters {
            // Keep the newest lines: the problem is usually at the end.
            log = "（較早的紀錄已省略）\n" + String(log.suffix(maxLogCharacters - 20))
        }
        let formatter = ISO8601DateFormatter()
        return ErrorReport(
            reportId: id.uuidString,
            createdAt: formatter.string(from: now),
            appVersion: environment.appVersion,
            appBuild: environment.appBuild,
            appCommit: environment.appCommit,
            deviceModel: environment.deviceModel,
            osVersion: environment.osVersion,
            description: String(description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxDescription)),
            includesTranscripts: includeTranscripts,
            audioCount: audioCount,
            settings: config.diagnosticSummary(),
            log: log
        )
    }
}

extension AppLogEntry {
    /// The log line, with recognized speech replaced when the user opted out.
    func reportLine(includeTranscript: Bool) -> String {
        guard !includeTranscript, transcript != nil else { return line }
        var copy = self
        copy.transcript = nil
        copy.transcriptTruncated = false
        return copy.line + "  文字=（使用者選擇不附上）"
    }
}

extension ConfigStore {
    /// Settings for a problem report: providers, models and service hosts,
    /// and only whether each key is filled in, never its value.
    public func diagnosticSummary() -> [String: String] {
        var summary: [String: String] = [:]
        for key in [ConfigKey.llmProvider, ConfigKey.speechProvider, ConfigKey.imageProvider,
                    ConfigKey.taiLoProvider, ConfigKey.taiwaneseFallback] {
            summary[key] = value(key)
        }
        for field in Self.fields {
            let raw = value(field.key).trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.secretKeys.contains(field.key) {
                summary[field.key] = raw.isEmpty ? "未設定" : "已設定"
            } else if field.key.hasSuffix("_URL") {
                summary[field.key] = raw.isEmpty ? "" : (URL(string: raw)?.host ?? "（格式錯誤）")
            } else {
                summary[field.key] = String(raw.prefix(200))
            }
        }
        return summary
    }
}

// MARK: Sending

public struct ErrorReportReceipt: Sendable, Equatable {
    public let issue: Int
}

public struct ErrorReportError: Error, Sendable, Equatable {
    public enum Kind: String, Sendable { case notConfigured, rateLimited, tooLarge, rejected, server, network }
    public let kind: Kind

    /// Worth keeping in the outbox and sending again later.
    public var isRetryable: Bool { [.rateLimited, .server, .network].contains(kind) }

    public var message: String {
        switch kind {
        case .notConfigured: "尚未設定錯誤回報網址，請到設定頁填寫。"
        case .rateLimited: "短時間內回報太多次，已先保存，稍後會自動重送。"
        case .tooLarge: "回報內容太大，請清除部分執行紀錄後再送。"
        case .rejected: "回報格式不被接受，請更新 App 後再試。"
        case .server: "回報服務暫時無法使用，已先保存，稍後會自動重送。"
        case .network: "目前連不上網路，已先保存，稍後會自動重送。"
        }
    }
}

/// Posts a report to the report Worker (`POST <base>/v1/reports`).
public struct ErrorReportSender: Sendable {
    public let baseURL: String
    public let transport: HTTPTransport
    let audioTransport: HTTPTransport

    public init(baseURL: String, client: HTTPSending = URLSession.shared) {
        self.baseURL = baseURL
        transport = HTTPTransport(client: client, timeout: .seconds(30), area: .report)
        audioTransport = HTTPTransport(client: client, timeout: .seconds(90), area: .report)
    }

    public func send(_ report: ErrorReport) async throws -> ErrorReportReceipt {
        let base = trimmedBase(baseURL)
        guard let url = URL(string: base + "/v1/reports"), url.scheme == "https", url.host != nil else {
            throw ErrorReportError(kind: .notConfigured)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(report)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw ErrorReportError(kind: .network)
        }
        switch response.statusCode {
        case 200, 201:
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard let issue = body?["issue"] as? Int else { throw ErrorReportError(kind: .server) }
            return ErrorReportReceipt(issue: issue)
        case 429: throw ErrorReportError(kind: .rateLimited)
        case 413: throw ErrorReportError(kind: .tooLarge)
        case 400, 404, 405: throw ErrorReportError(kind: .rejected)
        default: throw ErrorReportError(kind: .server)
        }
    }

    /// Uploads one recording for a report already filed (`POST <base>/v1/reports/<id>/audio/<index>`).
    public func sendAudio(reportId: String, index: Int, file: URL) async throws {
        let base = trimmedBase(baseURL)
        guard let url = URL(string: base + "/v1/reports/\(reportId)/audio/\(index)"), url.scheme == "https" else {
            throw ErrorReportError(kind: .notConfigured)
        }
        let body: Data
        do { body = try Data(contentsOf: file) } catch { throw ErrorReportError(kind: .rejected) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let response: HTTPURLResponse
        do {
            (_, response) = try await audioTransport.send(request)
        } catch {
            throw ErrorReportError(kind: .network)
        }
        switch response.statusCode {
        case 200, 201: return
        case 429: throw ErrorReportError(kind: .rateLimited)
        case 413: throw ErrorReportError(kind: .tooLarge)
        case 400, 404, 405: throw ErrorReportError(kind: .rejected)
        default: throw ErrorReportError(kind: .server)
        }
    }
}

/// Reports that could not be sent yet, kept as JSON files until they are.
public actor ErrorReportOutbox {
    public let directory: URL

    public init(directory: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? documents.appending(path: "reminicare_reports")
    }

    public func save(_ report: ErrorReport) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: file(report.reportId), options: [.atomic, .completeFileProtection])
    }

    public func pending() -> [ErrorReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ErrorReport.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func remove(_ reportId: String) {
        try? FileManager.default.removeItem(at: file(reportId))
    }

    private func file(_ reportId: String) -> URL {
        directory.appending(path: reportId.filter { $0.isHexDigit || $0 == "-" } + ".json")
    }
}

/// Sends a report, keeping it in the outbox when it can be retried later.
public struct ErrorReportService: Sendable {
    public let sender: ErrorReportSender
    public let outbox: ErrorReportOutbox

    public init(sender: ErrorReportSender, outbox: ErrorReportOutbox = ErrorReportOutbox()) {
        self.sender = sender
        self.outbox = outbox
    }

    public static func live(config: ConfigStore = .shared) -> ErrorReportService {
        ErrorReportService(sender: ErrorReportSender(baseURL: config.value(ConfigKey.errorReportURL)))
    }

    public enum Outcome: Sendable, Equatable {
        case sent(issue: Int)
        case saved(ErrorReportError)
        case failed(ErrorReportError)
    }

    public func submit(_ report: ErrorReport) async -> Outcome {
        AppLog.shared.record(.report, .started, detail: "errorReport")
        do {
            let receipt = try await sender.send(report)
            await outbox.remove(report.reportId)
            AppLog.shared.record(.report, .completed, detail: "errorReport")
            return .sent(issue: receipt.issue)
        } catch {
            let failure = error as? ErrorReportError ?? ErrorReportError(kind: .network)
            AppLog.shared.record(.report, .failed, detail: "report_\(failure.kind.rawValue)")
            guard failure.isRetryable else {
                // Sending it again would fail the same way.
                await outbox.remove(report.reportId)
                return .failed(failure)
            }
            do {
                try await outbox.save(report)
                return .saved(failure)
            } catch {
                return .failed(failure)
            }
        }
    }

    /// Sends what is waiting in the outbox; returns the issues filed.
    public func resendPending() async -> [Int] {
        var issues: [Int] = []
        for report in await outbox.pending() {
            switch await submit(report) {
            case .sent(let issue): issues.append(issue)
            case .saved: return issues // still offline or limited: try again later
            case .failed: continue
            }
        }
        return issues
    }

    public func pendingCount() async -> Int { await outbox.pending().count }

    /// Uploads recordings for a report that was just filed; returns how many
    /// arrived. A failed upload never undoes the report itself.
    /// shortcut: reports kept in the outbox go without audio; store the files with them if offline reports need it.
    public func uploadAudio(reportId: String, files: [URL]) async -> Int {
        var sent = 0
        for (index, file) in files.enumerated() {
            do {
                try await sender.sendAudio(reportId: reportId, index: index, file: file)
                sent += 1
                AppLog.shared.record(.report, .completed, detail: "reportAudio")
            } catch {
                AppLog.shared.record(.report, .failed, detail: "report_audio_failed")
            }
        }
        return sent
    }
}

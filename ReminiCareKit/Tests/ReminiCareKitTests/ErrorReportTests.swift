import Foundation
import Testing
@testable import ReminiCareKit

private let sentinel = "SENTINEL-SECRET-9f3a"
private let environment = ReportEnvironment(appVersion: "2.0.1", appBuild: "7", deviceModel: "iPad13,4", osVersion: "18.1")

private func configWithSecrets() throws -> ConfigStore {
    let secrets = MemorySecretStore()
    try secrets.write("OPENAI_API_KEY", value: sentinel)
    try secrets.write("YATING_API_KEY", value: sentinel + "-yating")
    try secrets.write(ConfigKey.speechWorkerToken, value: sentinel + "-worker")
    let defaults = UserDefaults(suiteName: "reminicare-tests-\(UUID().uuidString)")!
    defaults.set("openai", forKey: ConfigKey.llmProvider)
    defaults.set("https://user:\(sentinel)@llm.example.com/v1?key=\(sentinel)", forKey: "CUSTOM_LLM_BASE_URL")
    let config = ConfigStore(defaults: defaults, secrets: secrets)
    try config.load()
    return config
}

private func sampleEntries() -> [AppLogEntry] {
    let log = AppLog(capacity: 50)
    log.record(.app, .started)
    log.recordTranscription("我沒有吃過，不", operationId: 2)
    log.record(.stt, .warning, detail: "emptyTranscript")
    return log.entries
}

@Suite struct ErrorReportBuilderTests {
    @Test func summaryNeverContainsKeyValues() throws {
        let config = try configWithSecrets()
        let summary = config.diagnosticSummary()
        #expect(summary["OPENAI_API_KEY"] == "已設定")
        #expect(summary["GEMINI_API_KEY"] == "未設定")
        #expect(summary["CUSTOM_LLM_BASE_URL"] == "llm.example.com")
        #expect(summary[ConfigKey.llmProvider] == "openai")
        #expect(summary["OPENAI_LLM_MODEL"] == "gpt-4o-mini")
        for (key, value) in summary {
            #expect(!key.contains(sentinel) && !value.contains(sentinel))
        }
    }

    @Test func reportBodyHasNoSecrets() throws {
        let report = ErrorReportBuilder.make(
            description: "辨識錯字", includeTranscripts: true, entries: sampleEntries(),
            config: try configWithSecrets(), environment: environment
        )
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains(sentinel))
        #expect(report.appVersion == "2.0.1")
        #expect(report.deviceModel == "iPad13,4")
    }

    @Test func carriesTheBuildCommit() throws {
        #expect(ReportEnvironment.commit("4fb9d35") == "4fb9d35")
        #expect(ReportEnvironment.commit(" 4fb9d35-dirty\n") == "4fb9d35-dirty")
        #expect(ReportEnvironment.commit("$(REMINICARE_COMMIT)") == nil)
        #expect(ReportEnvironment.commit("") == nil)
        #expect(ReportEnvironment.commit(nil) == nil)

        let stamped = ReportEnvironment(appVersion: "2.0.0", appBuild: "1", appCommit: "9f76801", deviceModel: "iPad", osVersion: "26")
        let report = ErrorReportBuilder.make(
            description: "", includeTranscripts: true, entries: [], config: try configWithSecrets(), environment: stamped
        )
        #expect(report.appCommit == "9f76801")
        let unstamped = ErrorReportBuilder.make(
            description: "", includeTranscripts: true, entries: [], config: try configWithSecrets(), environment: environment
        )
        let json = String(decoding: try JSONEncoder().encode(unstamped), as: UTF8.self)
        #expect(!json.contains("appCommit"))
    }

    @Test func transcriptsCanBeLeftOut() throws {
        let config = try configWithSecrets()
        let with = ErrorReportBuilder.make(
            description: "", includeTranscripts: true, entries: sampleEntries(), config: config, environment: environment
        )
        #expect(with.log.contains("我沒有吃過，不"))
        let without = ErrorReportBuilder.make(
            description: "", includeTranscripts: false, entries: sampleEntries(), config: config, environment: environment
        )
        #expect(!without.log.contains("我沒有吃過"))
        #expect(without.log.contains("使用者選擇不附上"))
        #expect(without.log.contains("辨識完成但沒有任何文字"))
        #expect(!without.includesTranscripts)
    }

    @Test func limitsDescriptionAndKeepsTheNewestLog() throws {
        let log = AppLog(capacity: 5_000)
        for index in 0..<4_000 { log.recordTranscription("第\(index)段" + String(repeating: "字", count: 100), operationId: index) }
        let report = ErrorReportBuilder.make(
            description: String(repeating: "長", count: 3_000), includeTranscripts: true, entries: log.entries,
            config: try configWithSecrets(), environment: environment
        )
        #expect(report.description.count == ErrorReportBuilder.maxDescription)
        #expect(report.log.count <= ErrorReportBuilder.maxLogCharacters)
        #expect(report.log.contains("第3999段"))
        #expect(!report.log.contains("第0段"))
    }
}

@Suite struct ErrorReportSendingTests {
    func report() throws -> ErrorReport {
        ErrorReportBuilder.make(
            description: "test", includeTranscripts: true, entries: sampleEntries(),
            config: try configWithSecrets(), environment: environment
        )
    }

    @Test func postsJsonToTheWorker() async throws {
        let seen = LockedValue<URLRequest?>(nil)
        let http = FakeHTTP { request in
            seen.withValue { $0 = request }
            return (201, #"{"issue":42,"logComplete":true}"#)
        }
        let sender = ErrorReportSender(baseURL: "https://reports.example/", client: http)
        let sample = try report()
        #expect(try await sender.send(sample) == ErrorReportReceipt(issue: 42))
        let request = try #require(seen.current)
        #expect(request.url?.absoluteString == "https://reports.example/v1/reports")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONDecoder().decode(ErrorReport.self, from: try #require(request.httpBody))
        #expect(body == sample)
    }

    @Test func mapsStatusCodes() async throws {
        let sample = try report()
        for (status, kind) in [(429, ErrorReportError.Kind.rateLimited), (413, .tooLarge), (400, .rejected), (502, .server)] {
            let sender = ErrorReportSender(baseURL: "https://reports.example", client: FakeHTTP { _ in (status, "{}") })
            await #expect(throws: ErrorReportError(kind: kind)) { try await sender.send(sample) }
        }
        let insecure = ErrorReportSender(baseURL: "http://reports.example", client: FakeHTTP { _ in (201, "{}") })
        await #expect(throws: ErrorReportError(kind: .notConfigured)) { try await insecure.send(sample) }
    }

    @Test func keepsRetryableReportsUntilTheyAreSent() async throws {
        let online = LockedValue(false)
        let http = FakeHTTP { _ in online.current ? (201, #"{"issue":7}"#) : (503, "{}") }
        let outbox = ErrorReportOutbox(directory: try temporaryDirectory())
        let service = ErrorReportService(sender: ErrorReportSender(baseURL: "https://reports.example", client: http), outbox: outbox)
        let sample = try report()

        #expect(await service.submit(sample) == .saved(ErrorReportError(kind: .server)))
        #expect(await service.pendingCount() == 1)
        #expect(await service.resendPending() == [])

        online.withValue { $0 = true }
        #expect(await service.resendPending() == [7])
        #expect(await service.pendingCount() == 0)
    }

    @Test func dropsReportsThatCannotBeAccepted() async throws {
        let outbox = ErrorReportOutbox(directory: try temporaryDirectory())
        let sample = try report()
        try await outbox.save(sample)
        let sender = ErrorReportSender(baseURL: "https://reports.example", client: FakeHTTP { _ in (400, "{}") })
        let service = ErrorReportService(sender: sender, outbox: outbox)
        #expect(await service.submit(sample) == .failed(ErrorReportError(kind: .rejected)))
        #expect(await service.pendingCount() == 0)
    }
}

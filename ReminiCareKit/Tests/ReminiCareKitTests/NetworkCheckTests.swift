import Foundation
import Testing
@testable import ReminiCareKit

/// Answers by host; a host mapped to a URLError fails with it.
struct HostHTTP: HTTPSending {
    let failures: [String: URLError.Code]
    let flaky: LockedValue<[String: Int]>
    let seen = LockedValue<[URLRequest]>([])

    init(failures: [String: URLError.Code] = [:], flaky: [String: Int] = [:]) {
        self.failures = failures
        self.flaky = LockedValue(flaky)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        seen.withValue { $0.append(request) }
        let host = request.url?.host ?? ""
        if let code = failures[host] { throw URLError(code) }
        let failNow = flaky.withValue { left -> Bool in
            guard let count = left[host], count > 0 else { return false }
            left[host] = count - 1
            return true
        }
        if failNow { throw URLError(.networkConnectionLost) }
        let body: String
        let status: Int
        switch host {
        case "captive.apple.com": (status, body) = (200, "<HTML><BODY>Success</BODY></HTML>")
        case "asr.api.yating.tw" where request.url?.path == "/v1/token": (status, body) = (201, #"{"success":true,"auth_token":"t"}"#)
        default: (status, body) = (404, "{}")
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct ReadyChannel: YatingChannel {
    let reply: String?
    func send(_ data: Data) async throws {}
    func receive() async throws -> String? { reply }
    func close() {}
}

@MainActor
@Suite struct NetworkCheckTests {
    func config(speech: String = "yating", yatingKey: String = "key") throws -> ConfigStore {
        let secrets = MemorySecretStore()
        try secrets.write("YATING_API_KEY", value: yatingKey)
        try secrets.write("NVIDIA_API_KEY", value: "SENTINEL-nvidia")
        let defaults = UserDefaults(suiteName: "reminicare-tests-\(UUID().uuidString)")!
        defaults.set(speech, forKey: ConfigKey.speechProvider)
        let config = ConfigStore(defaults: defaults, secrets: secrets)
        try config.load()
        return config
    }

    func check(
        _ http: HostHTTP, reply: String? = #"{"status":"ok"}"#, config: ConfigStore,
        environment: NetworkEnvironment = NetworkEnvironment(interface: .wifi)
    ) -> NetworkCheck {
        NetworkCheck(
            config: config, http: http, connect: { _ in ReadyChannel(reply: reply) },
            environment: { environment }, timeout: .seconds(2)
        )
    }

    func item(_ check: NetworkCheck, _ id: String) throws -> NetworkCheckItem {
        try #require(check.items.first { $0.id == id })
    }

    @Test func allReachable() async throws {
        let http = HostHTTP()
        let check = check(http, config: try config())
        await check.run()
        #expect(check.items.map(\.id) == ["internet", "yatingHttps", "llm", "image", "report", "yatingWs"])
        #expect(check.items.allSatisfy { $0.status == .ok && $0.successes == 3 })
        #expect(check.reportText.contains("網路：Wi-Fi"))
        // Keys go nowhere: no request carries one except Yating's own token request.
        for request in http.seen.current {
            let headers = request.allHTTPHeaderFields ?? [:]
            #expect(!headers.values.contains { $0.contains("SENTINEL") })
            if request.url?.path != "/v1/token" { #expect(headers["Authorization"] == nil && headers["key"] == nil) }
        }
        #expect(!check.reportText.contains("SENTINEL"))
    }

    @Test func blockedWebSocketIsNamed() async throws {
        let check = check(HostHTTP(), reply: nil, config: try config())
        await check.run()
        let socket = try item(check, "yatingWs")
        #expect(socket.status == .failed)
        #expect(socket.failure == .closed)
        #expect(try item(check, "yatingHttps").status == .ok)
    }

    @Test func classifiesBlockedHosts() async throws {
        let http = HostHTTP(failures: [
            "integrate.api.nvidia.com": .cannotFindHost,
            "reminicare-image-api.hding49.workers.dev": .secureConnectionFailed,
            "reminicare-report-api.hding49.workers.dev": .cannotConnectToHost,
        ])
        let check = check(http, config: try config())
        await check.run()
        #expect(try item(check, "llm").failure == .dns)
        #expect(try item(check, "image").failure == .tls)
        #expect(try item(check, "report").failure == .refused)
        #expect(try item(check, "report").status == .failed)
    }

    @Test func flakyConnectionIsPartial() async throws {
        let check = check(HostHTTP(flaky: ["reminicare-report-api.hding49.workers.dev": 1]), config: try config())
        await check.run()
        let report = try item(check, "report")
        #expect(report.status == .partial)
        #expect(report.successes == 2)
        #expect(report.failure == .lost)
    }

    @Test func detectsLoginPage() async throws {
        struct Portal: HTTPSending {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                (Data("<html>請先登入</html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let check = NetworkCheck(
            config: try config(), http: Portal(), connect: { _ in ReadyChannel(reply: nil) },
            environment: { NetworkEnvironment(interface: .wifi) }, timeout: .seconds(2)
        )
        await check.run()
        #expect(try item(check, "internet").failure == .captivePortal)
    }

    @Test func offlineSkipsRequests() async throws {
        let http = HostHTTP()
        let check = check(http, config: try config(), environment: NetworkEnvironment(interface: .none))
        await check.run()
        #expect(http.seen.current.isEmpty)
        #expect(check.items.allSatisfy { $0.status == .failed && $0.failure == .offline })
    }

    @Test func nckuChecksItsOwnHostInstead() async throws {
        let check = check(HostHTTP(), config: try config(speech: "ncku"))
        await check.run()
        #expect(check.items.map(\.id) == ["internet", "nckuStt", "llm", "image", "report"])
    }

    @Test func noYatingKeySkipsTheSocket() async throws {
        let check = check(HostHTTP(), config: try config(yatingKey: ""))
        await check.run()
        #expect(try item(check, "yatingWs").status == .skipped)
    }

    @Test func everyLoggedCodeHasALabel() async throws {
        let check = check(HostHTTP(failures: ["captive.apple.com": .timedOut]), reply: nil, config: try config())
        await check.run()
        let codes = ["netCheck", "netEnv_wifi", "netEnvVpn", "netEnvProxy"]
            + ["internet", "yatingHttps", "yatingWs", "nckuStt", "llm", "image", "report"].map { "netTarget_\($0)" }
            + ["offline", "dns", "refused", "lost", "tls", "timeout", "captivePortal", "httpError", "tokenRejected", "notReady", "closed", "unexpected"].map { "netReason_\($0)" }
        for code in codes { #expect(AppLog.detailLabels[code] != nil, "\(code)") }
    }
}

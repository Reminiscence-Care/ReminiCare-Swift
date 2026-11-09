import CFNetwork
import Foundation
import Network
import Observation

/// What kind of connection the iPad is on, read once when a check starts.
public struct NetworkEnvironment: Sendable, Equatable {
    public enum Interface: String, Sendable { case wifi, cellular, wired, other, none }
    public var interface: Interface
    public var isConstrained: Bool
    public var usesVPN: Bool
    public var usesProxy: Bool

    public init(interface: Interface, isConstrained: Bool = false, usesVPN: Bool = false, usesProxy: Bool = false) {
        self.interface = interface
        self.isConstrained = isConstrained
        self.usesVPN = usesVPN
        self.usesProxy = usesProxy
    }

    public var label: String {
        let name = switch interface {
        case .wifi: "Wi-Fi"
        case .cellular: "行動網路"
        case .wired: "有線網路"
        case .other: "其他網路"
        case .none: "沒有網路"
        }
        var parts = [name]
        if usesVPN { parts.append("VPN") }
        if usesProxy { parts.append("代理伺服器") }
        if isConstrained { parts.append("低數據模式") }
        return parts.joined(separator: "・")
    }

    /// One reading of the system network path and proxy settings.
    public static func current() async -> NetworkEnvironment {
        let (interface, constrained) = await withCheckedContinuation { (continuation: CheckedContinuation<(Interface, Bool), Never>) in
            let monitor = NWPathMonitor()
            let pending = LockedValue<NWPathMonitor?>(monitor)
            monitor.pathUpdateHandler = { path in
                guard let monitor = pending.withValue({ value -> NWPathMonitor? in
                    defer { value = nil }
                    return value
                }) else { return }
                monitor.cancel()
                let interface: Interface
                if path.status != .satisfied {
                    interface = .none
                } else if path.usesInterfaceType(.wifi) {
                    interface = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    interface = .cellular
                } else if path.usesInterfaceType(.wiredEthernet) {
                    interface = .wired
                } else {
                    interface = .other
                }
                continuation.resume(returning: (interface, path.isConstrained))
            }
            monitor.start(queue: DispatchQueue(label: "reminicare.network-check"))
        }
        let proxy = (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:]
        let scoped = Array(((proxy["__SCOPED__"] as? [String: Any]) ?? [:]).keys)
        let vpn = scoped.contains { name in ["utun", "ipsec", "ppp", "tap", "tun"].contains { name.hasPrefix($0) } }
        let usesProxy = (proxy["HTTPEnable"] as? Int) == 1 || (proxy["HTTPSEnable"] as? Int) == 1
            || (proxy["ProxyAutoConfigEnable"] as? Int) == 1
        return NetworkEnvironment(interface: interface, isConstrained: constrained, usesVPN: vpn, usesProxy: usesProxy)
    }
}

/// Why a connection attempt failed, in words someone on site can act on.
public enum NetworkFailure: String, Sendable, Equatable {
    case offline, dns, refused, lost, tls, timeout, captivePortal, httpError, tokenRejected, notReady, closed, unauthorized, unexpected

    public var advice: String {
        switch self {
        case .offline: "iPad 目前沒有連上網路。"
        case .dns: "找不到這個網址（DNS 失敗）：網路可能封鎖了這個網域，或 DNS 有問題。"
        case .refused: "連線被拒絕：可能被防火牆擋住。"
        case .lost: "連線中途斷掉：網路不穩定。"
        case .tls: "加密連線被攔截：常見於學校或公司防火牆、代理伺服器的流量檢查。"
        case .timeout: "等太久沒有回應：網路很慢，或連線被防火牆默默丟掉。"
        case .captivePortal: "這個 Wi-Fi 要先在瀏覽器登入（例如學校或飯店網路），登入後才能正常上網。"
        case .httpError: "伺服器有回應，但回傳錯誤。"
        case .tokenRejected: "雅婷拒絕取得連線憑證：請確認 Key 或額度（服務狀態頁可查）。"
        case .notReady: "已連上雅婷，但伺服器沒有回報就緒。"
        case .closed: "辨識連線一建立就被關閉：很可能是防火牆或代理伺服器不允許 WebSocket。"
        case .unauthorized: "語音 Worker 不接受這個 App Token：請到設定頁確認「語音 Worker App Token」。"
        case .unexpected: "未預期的錯誤。"
        }
    }

    static func from(_ error: Error) -> NetworkFailure {
        if error is TimeoutError { return .timeout }
        if let stt = error as? SttError {
            return switch stt.kind {
            case .timeout: .timeout
            case .authentication, .server, .invalidResponse: .tokenRejected
            default: .unexpected
            }
        }
        guard let url = error as? URLError else { return .unexpected }
        switch url.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
        case .cannotFindHost, .dnsLookupFailed: return .dns
        case .cannotConnectToHost: return .refused
        case .networkConnectionLost: return .lost
        case .timedOut: return .timeout
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return .tls
        case .badServerResponse: return .closed
        default: return .unexpected
        }
    }
}

public struct NetworkCheckItem: Sendable, Identifiable, Equatable {
    public enum Status: String, Sendable { case ok, slow, partial, failed, warning, skipped }

    public let id: String
    public let title: String
    public var status: Status
    public var attempts = 0
    public var successes = 0
    public var medianMs: Int?
    public var failure: NetworkFailure?
    public var note: String?

    public var summary: String {
        var parts: [String] = []
        if attempts > 0 { parts.append("成功 \(successes)/\(attempts)") }
        if let medianMs { parts.append("約 \(medianMs) ms") }
        if let note { parts.append(note) }
        if let failure { parts.append(failure.advice) }
        return parts.joined(separator: "，")
    }
}

/// Settings → 網路檢測: whether this network can reach each service the app
/// uses, including the WebSocket that speech recognition needs and that
/// firewalls often block. Sends no keys to anything but their own service,
/// no audio and no conversation content.
@MainActor
@Observable
public final class NetworkCheck {
    public nonisolated static let attempts = 3
    public nonisolated static let slowMs = 3_000

    /// Before a conversation: one try per service, short timeout, no report or
    /// WebSocket check. Only meant to warn, never to block.
    public static func quick(config: ConfigStore = .shared) -> NetworkCheck {
        NetworkCheck(config: config, timeout: .seconds(5), attempts: 1, quick: true)
    }

    public private(set) var running = false
    public private(set) var environment: NetworkEnvironment?
    public private(set) var items: [NetworkCheckItem] = []
    public private(set) var finishedAt: Date?

    @ObservationIgnored private let config: ConfigStore
    @ObservationIgnored private let http: HTTPSending
    @ObservationIgnored private let connect: @Sendable (URL) -> YatingChannel
    @ObservationIgnored private let readEnvironment: @Sendable () async -> NetworkEnvironment
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private let attemptCount: Int
    @ObservationIgnored private let quick: Bool

    /// Items that failed outright in the last run, for a warning.
    public var failedItems: [NetworkCheckItem] { items.filter { $0.status == .failed } }

    public init(
        config: ConfigStore = .shared,
        http: HTTPSending = URLSession(configuration: .ephemeral),
        connect: @escaping @Sendable (URL) -> YatingChannel = { URLSessionYatingChannel(url: $0) },
        environment: @escaping @Sendable () async -> NetworkEnvironment = { await NetworkEnvironment.current() },
        timeout: Duration = .seconds(10),
        attempts: Int = NetworkCheck.attempts,
        quick: Bool = false
    ) {
        attemptCount = attempts
        self.quick = quick
        self.config = config
        self.http = http
        self.connect = connect
        readEnvironment = environment
        self.timeout = timeout
    }

    private struct Target {
        let id: String
        let title: String
        let url: URL
    }

    private var speech: SpeechProvider { SpeechProvider(config.value(ConfigKey.speechProvider)) }

    private var targets: [Target] {
        let factory = ServiceFactory(config: config)
        var list: [Target] = []
        func add(_ id: String, _ title: String, _ raw: String) {
            if let url = URL(string: trimmedBase(raw)), url.host != nil { list.append(Target(id: id, title: title, url: url)) }
        }
        switch speech {
        case .ncku:
            let stt = config.value("NCKU_STT_URL")
            add("nckuStt", "成大語音辨識", stt.isEmpty ? ConfigKey.defaultNckuSttURL : stt)
        case .yatingDirect:
            add("yatingHttps", "雅婷（HTTPS）", "https://asr.api.yating.tw")
        case .yating:
            break // checkSpeechWorker
        }
        let llm = factory.llmConfig()
        add("llm", "語言模型（\(llm.displayName)）", llm.baseURL)
        add("image", "生圖（\(factory.imageConfig().displayName)）", factory.imageConfig().baseURL)
        if !quick { add("report", "錯誤回報", config.value(ConfigKey.errorReportURL)) }
        return list
    }

    public func run() async {
        guard !running else { return }
        running = true
        finishedAt = nil
        AppLog.shared.record(.network, .started, detail: quick ? "netQuickCheck" : "netCheck")
        let environment = await readEnvironment()
        self.environment = environment
        AppLog.shared.record(.network, .progress, detail: "netEnv_\(environment.interface.rawValue)")
        if environment.usesVPN { AppLog.shared.record(.network, .warning, detail: "netEnvVpn") }
        if environment.usesProxy { AppLog.shared.record(.network, .warning, detail: "netEnvProxy") }

        let targets = targets
        let usesWorker = speech == .yating
        let usesSocket = speech == .yatingDirect && !quick
        items = [NetworkCheckItem(id: "internet", title: "一般上網", status: .skipped)]
            + (usesWorker ? [NetworkCheckItem(id: "speechWorker", title: Self.workerTitle, status: .skipped)] : [])
            + targets.map { NetworkCheckItem(id: $0.id, title: $0.title, status: .skipped) }
            + (usesSocket ? [NetworkCheckItem(id: "yatingWs", title: "雅婷語音辨識連線（WebSocket）", status: .skipped)] : [])

        if environment.interface == .none {
            for index in items.indices { items[index].status = .failed; items[index].failure = .offline }
        } else {
            update(await checkInternet())
            if usesWorker { update(await checkSpeechWorker()) }
            for target in targets { update(await checkHTTPS(target)) }
            if usesSocket { update(await checkYatingSocket()) }
        }
        for item in items { log(item) }
        AppLog.shared.record(.network, .completed, detail: quick ? "netQuickCheck" : "netCheck")
        finishedAt = Date()
        running = false
    }

    private func update(_ item: NetworkCheckItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
    }

    private func log(_ item: NetworkCheckItem) {
        let event: LogEvent = switch item.status {
        case .ok: .completed
        case .slow, .partial, .warning: .warning
        case .failed: .failed
        case .skipped: .progress
        }
        AppLog.shared.record(
            .network, event, durationMs: item.medianMs,
            complete: item.attempts > 0 ? item.successes : nil, total: item.attempts > 0 ? item.attempts : nil,
            detail: "netTarget_\(item.id)"
        )
        if let failure = item.failure { AppLog.shared.record(.network, .warning, detail: "netReason_\(failure.rawValue)") }
    }

    // MARK: Checks

    /// Apple's captive-portal page: a login wall answers with its own page.
    private func checkInternet() async -> NetworkCheckItem {
        var item = NetworkCheckItem(id: "internet", title: "一般上網", status: .ok)
        let url = URL(string: "http://captive.apple.com/hotspot-detect.html")!
        let outcome = await attempt { [http, timeout] in
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout.seconds
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let prepared = request
            let (data, response) = try await withTimeout(timeout) { try await http.send(prepared) }
            guard response.statusCode == 200, String(decoding: data, as: UTF8.self).contains("Success") else {
                throw CaptivePortal()
            }
        }
        item.apply(outcome)
        return item
    }

    /// Any HTTP answer at all proves the host is reachable; no key is sent.
    private func checkHTTPS(_ target: Target) async -> NetworkCheckItem {
        var item = NetworkCheckItem(id: target.id, title: target.title, status: .ok)
        let outcome = await attempt { [http, timeout] in
            var request = URLRequest(url: target.url)
            request.timeoutInterval = timeout.seconds
            let prepared = request
            _ = try await withTimeout(timeout) { try await http.send(prepared) }
        }
        item.apply(outcome)
        item.note = target.url.host
        return item
    }

    nonisolated static let workerTitle = "語音辨識（ReminiCare Worker）"

    /// `/health` proves the Worker is reachable; the full check also asks it to
    /// fetch a Yating token (`/v1/check`, no audio), which checks the app token
    /// and the Worker's Yating key and quota.
    private func checkSpeechWorker() async -> NetworkCheckItem {
        var item = NetworkCheckItem(id: "speechWorker", title: Self.workerTitle, status: .ok)
        let endpoint = config.speechWorker
        guard let health = endpoint.url("/health"), let check = endpoint.request("/v1/check", method: "GET") else {
            item.status = .failed
            item.failure = .unexpected
            item.note = "語音 Worker 網址必須是 HTTPS"
            return item
        }
        let full = !quick && !endpoint.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let requests = full ? [URLRequest(url: health), check] : [URLRequest(url: health)]
        let outcome = await attempt { [http, timeout] in
            for original in requests {
                var request = original
                request.timeoutInterval = timeout.seconds
                let prepared = request
                let (data, response) = try await withTimeout(timeout) { try await http.send(prepared) }
                guard response.statusCode == 200 else {
                    if response.statusCode == 401 { throw WorkerRejected(failure: .unauthorized) }
                    let code = SpeechWorkerEndpoint.errorCode(data)
                    throw WorkerRejected(failure: ["quota", "upstream_auth"].contains(code) ? .tokenRejected : .httpError)
                }
            }
        }
        item.apply(outcome)
        item.note = health.host
        return item
    }

    /// The path recognition really uses: token, WebSocket, server "ready".
    /// Closes as soon as the server is ready, without sending audio.
    private func checkYatingSocket() async -> NetworkCheckItem {
        var item = NetworkCheckItem(id: "yatingWs", title: "雅婷語音辨識連線（WebSocket）", status: .ok)
        let apiKey = config.value("YATING_API_KEY").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            item.status = .skipped
            item.note = "尚未設定雅婷 Key"
            return item
        }
        let outcome = await attempt { [http, connect, timeout] in
            let token = try await yatingToken(apiKey: apiKey, http: http)
            guard let url = URL(string: "wss://asr.api.yating.tw/ws/v1/?token=\(token)") else { throw URLError(.badURL) }
            let channel = connect(url)
            defer { channel.close() }
            try await withTimeout(timeout) {
                while true {
                    guard let message = try await channel.receive() else { throw URLError(.badServerResponse) }
                    let object = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any]
                    if object?["status"] as? String == "ok" { return }
                    if object?["status"] as? String == "error" { throw NotReady() }
                }
            }
        }
        item.apply(outcome)
        return item
    }

    private struct CaptivePortal: Error {}
    private struct NotReady: Error {}
    private struct WorkerRejected: Error { let failure: NetworkFailure }

    struct Outcome {
        var times: [Int] = []
        var failures: [NetworkFailure] = []
    }

    private func attempt(_ operation: @escaping @Sendable () async throws -> Void) async -> Outcome {
        var outcome = Outcome()
        for _ in 0..<attemptCount {
            let watch = Stopwatch()
            do {
                try await operation()
                outcome.times.append(watch.milliseconds)
            } catch is CaptivePortal {
                outcome.failures.append(.captivePortal)
            } catch is NotReady {
                outcome.failures.append(.notReady)
            } catch let rejected as WorkerRejected {
                outcome.failures.append(rejected.failure)
            } catch {
                outcome.failures.append(NetworkFailure.from(error))
            }
        }
        return outcome
    }

    /// Plain text for "copy results": statuses and hosts only.
    public var reportText: String {
        var lines = ["ReminiCare 網路檢測"]
        if let environment { lines.append("網路：\(environment.label)") }
        for item in items { lines.append("\(item.status.symbol) \(item.title)：\(item.summary.isEmpty ? item.status.label : item.summary)") }
        return lines.joined(separator: "\n")
    }
}

extension NetworkCheckItem {
    mutating func apply(_ outcome: NetworkCheck.Outcome) {
        attempts = outcome.times.count + outcome.failures.count
        successes = outcome.times.count
        let sorted = outcome.times.sorted()
        medianMs = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        // The most common failure explains it best.
        failure = Dictionary(grouping: outcome.failures, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        if successes == 0 {
            status = .failed
        } else if successes < attempts {
            status = .partial
        } else if (medianMs ?? 0) > NetworkCheck.slowMs {
            status = .slow
        } else {
            status = .ok
        }
    }
}

extension NetworkCheckItem.Status {
    public var label: String {
        switch self {
        case .ok: "正常"
        case .slow: "連得上但很慢"
        case .partial: "時好時壞"
        case .failed: "連不上"
        case .warning: "注意"
        case .skipped: "未檢查"
        }
    }

    public var symbol: String {
        switch self {
        case .ok: "✅"
        case .slow, .partial, .warning: "⚠️"
        case .failed: "❌"
        case .skipped: "－"
        }
    }
}

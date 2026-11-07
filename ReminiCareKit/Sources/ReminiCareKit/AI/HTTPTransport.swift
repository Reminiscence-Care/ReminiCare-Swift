import Foundation

public protocol HTTPSending: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPSending {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Logs each request's timing and status without recording URLs or bodies.
/// Task cancellation aborts the underlying request.
public struct HTTPTransport: Sendable {
    private static let counter = LockedValue(0)
    public let client: HTTPSending
    public let timeout: Duration
    public let area: LogArea

    public init(client: HTTPSending = URLSession.shared, timeout: Duration, area: LogArea) {
        self.client = client
        self.timeout = timeout
        self.area = area
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let id = Self.counter.withValue { $0 += 1; return $0 }
        let watch = Stopwatch()
        AppLog.shared.record(area, .requestStarted, operationId: id)
        var timed = request
        timed.timeoutInterval = timeout.seconds
        let request = timed
        do {
            let client = client
            let (data, response) = try await withTimeout(timeout) { try await client.send(request) }
            AppLog.shared.record(area, .requestCompleted, operationId: id, durationMs: watch.milliseconds, bytes: data.count, statusCode: response.statusCode)
            return (data, response)
        } catch {
            let detail: String
            if error is TimeoutError || (error as? URLError)?.code == .timedOut {
                detail = "timeout"
            } else if error is CancellationError || (error as? URLError)?.code == .cancelled {
                detail = "cancelled"
            } else {
                detail = "network"
            }
            AppLog.shared.record(area, .requestFailed, operationId: id, durationMs: watch.milliseconds, detail: detail)
            throw error
        }
    }

    static func jsonRequest(_ url: URL, bearer: String? = nil, headers: [String: String] = [:], body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

func trimmedBase(_ base: String) -> String {
    var value = base.trimmingCharacters(in: .whitespaces)
    while value.hasSuffix("/") { value.removeLast() }
    return value
}

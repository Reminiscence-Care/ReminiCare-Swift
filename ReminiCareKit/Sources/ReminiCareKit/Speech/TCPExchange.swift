import Foundation
import Network

public struct TCPError: Error, Sendable {
    public let message: String
}

/// Sends one payload over TCP and reads until the server closes the connection.
public protocol TCPExchanging: Sendable {
    func exchange(host: String, port: Int, tls: Bool, payload: Data, timeout: Duration, maximumBytes: Int) async throws -> Data
}

public struct NetworkTCPExchange: TCPExchanging {
    public init() {}

    public func exchange(host: String, port: Int, tls: Bool, payload: Data, timeout: Duration, maximumBytes: Int) async throws -> Data {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw TCPError(message: "port") }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: tls ? NWProtocolTLS.Options() : nil, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "reminicare.tcp")
        return try await withTaskCancellationHandler {
            try await withTimeout(timeout) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    let finished = LockedValue(false)
                    let buffer = LockedValue(Data())
                    @Sendable func finish(_ result: Result<Data, Error>) {
                        let first = finished.withValue { done -> Bool in
                            defer { done = true }
                            return !done
                        }
                        guard first else { return }
                        connection.cancel()
                        continuation.resume(with: result)
                    }
                    @Sendable func read() {
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                            if let data {
                                let size = buffer.withValue { $0.append(data); return $0.count }
                                if size > maximumBytes { return finish(.failure(TCPError(message: "response too large"))) }
                            }
                            if complete { return finish(.success(buffer.current)) }
                            if let error { return finish(.failure(error)) }
                            read()
                        }
                    }
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            connection.send(content: payload, completion: .contentProcessed { error in
                                if let error { finish(.failure(error)) } else { read() }
                            })
                        case .failed(let error):
                            finish(.failure(error))
                        case .waiting(let error):
                            finish(.failure(error))
                        case .cancelled:
                            finish(.failure(CancellationError()))
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

import Foundation
import Network
import SnipperCore

/// A tiny HTTP/1.1 server on 127.0.0.1 that the browser extension talks to.
/// Each connection carries one request; responses close the connection.
final class LocalServer: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    typealias Handler = @MainActor (HTTPRequest) async -> HTTPResponse

    private let queue = DispatchQueue(label: "dev.grasco.snipper.server")
    private var listener: NWListener?
    private let handler: Handler
    private let maxBodyBytes = 40 * 1024 * 1024
    var onStateChange: (@MainActor (State) -> Void)?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start(port: UInt16) {
        queue.async { [self] in
            listener?.cancel()
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                // Loopback only: nothing outside this Mac can connect.
                parameters.requiredInterfaceType = .loopback
                guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
                let listener = try NWListener(using: parameters, on: nwPort)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.report(state, port: port)
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                publish(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            publish(.stopped)
        }
    }

    private func report(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            publish(.running(port: port))
        case .failed(let error):
            publish(.failed(Self.describe(error, port: port)))
            listener?.cancel()
        case .cancelled:
            break
        default:
            break
        }
    }

    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use."
        }
        return error.localizedDescription
    }

    private func publish(_ state: State) {
        let callback = onStateChange
        Task { @MainActor in callback?(state) }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        // Defense in depth on top of the loopback-only listener.
        if case .hostPort(let host, _) = connection.endpoint, !Self.isLoopback(host) {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        // Drop clients that never finish their request.
        queue.asyncAfter(deadline: .now() + 30) { [weak connection] in connection?.cancel() }
    }

    private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address): return address == .loopback || address.asIPv4 == .loopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil {
                connection.cancel()
                return
            }
            switch HTTPRequestParser.parse(buffer, maxBodyBytes: self.maxBodyBytes) {
            case .incomplete:
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            case .invalid(let status, let reason):
                self.send(.error(status, reason), on: connection)
            case .complete(let request):
                let handler = self.handler
                Task { @MainActor in
                    let response = await handler(request)
                    self.send(response, on: connection)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

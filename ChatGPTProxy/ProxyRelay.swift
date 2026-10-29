import Foundation
import Network

// 所有网络状态由串行队列管理，不记录请求地址、正文或认证信息。
final class ProxyRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.codex-gui-proxy.relay")
    private var listener: NWListener?
    private var endpoint: ProxyEndpoint?
    private var route: RelayRoute = .direct
    private var sessions: [UUID: RelaySession] = [:]
    private var pendingStart: CheckedContinuation<ProxyEndpoint, any Error>?
    private var startTimeout: DispatchWorkItem?
    private let connectionCountChanged: @Sendable (Int) -> Void
    private let failed: @Sendable (String) -> Void

    init(connectionCountChanged: @escaping @Sendable (Int) -> Void = { _ in },
         failed: @escaping @Sendable (String) -> Void = { _ in }) {
        self.connectionCountChanged = connectionCountChanged
        self.failed = failed
    }

    func start(port: UInt16? = nil, route: RelayRoute) async throws -> ProxyEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let endpoint {
                    continuation.resume(returning: endpoint)
                    return
                }
                guard listener == nil else {
                    continuation.resume(throwing: LauncherError.message("本机中转正在启动，请稍后重试。"))
                    return
                }
                do {
                    let parameters = NWParameters.tcp
                    let requestedPort = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: requestedPort)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.route = route
                    pendingStart = continuation
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self, let listener, self.listener === listener else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port?.rawValue else { return }
                            if case .proxy(let upstream) = self.route, upstream.isLocalRelay(port: port) {
                                self.listenerFailed("Clash 端口不能与本机中转端口相同。")
                                return
                            }
                            let endpoint = ProxyEndpoint(host: "127.0.0.1", port: port)
                            self.endpoint = endpoint
                            self.startTimeout?.cancel()
                            self.startTimeout = nil
                            self.pendingStart?.resume(returning: endpoint)
                            self.pendingStart = nil
                        case .failed(let error):
                            self.listenerFailed("本机中转启动失败：\(error.localizedDescription)。请检查端口是否被占用。")
                        default:
                            break
                        }
                    }
                    let timeout = DispatchWorkItem { [weak self] in
                        guard let self, self.pendingStart != nil else { return }
                        self.listenerFailed("本机中转启动超时。")
                    }
                    startTimeout = timeout
                    queue.asyncAfter(deadline: .now() + 5, execute: timeout)
                    listener.start(queue: queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    func setRoute(_ route: RelayRoute) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if case .proxy(let upstream) = route, let endpoint,
                   upstream.isLocalRelay(port: endpoint.port) {
                    continuation.resume(throwing: LauncherError.message("Clash 端口不能与本机中转端口相同。"))
                    return
                }
                guard self.route != route else {
                    continuation.resume(returning: 0)
                    return
                }
                self.route = route
                let count = sessions.count
                closeSessions()
                continuation.resume(returning: count)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopOnQueue()
                continuation.resume()
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let endpoint, sessions.count < 256 else {
            connection.cancel()
            return
        }
        let id = UUID()
        let session = RelaySession(id: id, client: connection, route: route,
                                   relayPort: endpoint.port, queue: queue) { [weak self] id in
            guard let self else { return }
            self.sessions.removeValue(forKey: id)
            self.connectionCountChanged(self.sessions.count)
        }
        sessions[id] = session
        connectionCountChanged(sessions.count)
        session.start()
    }

    private func closeSessions() {
        for session in Array(sessions.values) { session.close() }
    }

    private func listenerFailed(_ message: String) {
        pendingStart?.resume(throwing: LauncherError.message(message))
        pendingStart = nil
        stopOnQueue()
        failed(message)
    }

    private func stopOnQueue() {
        startTimeout?.cancel()
        startTimeout = nil
        pendingStart?.resume(throwing: CancellationError())
        pendingStart = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        endpoint = nil
        closeSessions()
    }
}

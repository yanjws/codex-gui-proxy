import Foundation
import Network

enum ProxyPortChecker {
    static func check(_ endpoint: ProxyEndpoint) async throws {
        let attempt = PortCheckAttempt(endpoint: endpoint)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                attempt.start(continuation)
            }
        } onCancel: {
            attempt.cancel()
        }
    }
}

// 可变状态仅在同一串行队列访问；连接完成、超时和取消只会恢复一次 continuation。
private final class PortCheckAttempt: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.codex-gui-proxy.port-check")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timeout: DispatchWorkItem?
    private var cancelled = false

    init(endpoint: ProxyEndpoint) {
        connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port)!,
            using: .tcp
        )
    }

    func start(_ continuation: CheckedContinuation<Void, any Error>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !cancelled else {
                finish(.failure(CancellationError()))
                return
            }
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error), .waiting(let error):
                    finish(.failure(LauncherError.message("代理端口连接失败：\(error.localizedDescription)")))
                default:
                    break
                }
            }
            let timeout = DispatchWorkItem { [self] in
                finish(.failure(LauncherError.message("代理端口连接超时，请检查主机、端口及代理客户端。")))
            }
            self.timeout = timeout
            queue.asyncAfter(deadline: .now() + 3, execute: timeout)
            connection.start(queue: queue)
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}

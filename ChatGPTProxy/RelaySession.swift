import Foundation
import Network

// 生命周期及回调均在 ProxyRelay 的串行队列运行。
final class RelaySession: @unchecked Sendable {
    private let id: UUID
    private let client: NWConnection
    private let route: RelayRoute
    private let relayPort: UInt16
    private let queue: DispatchQueue
    private let didClose: @Sendable (UUID) -> Void
    private var upstream: NWConnection?
    private var timeout: DispatchWorkItem?
    private var closed = false
    private var rejecting = false
    private var streaming = false
    private var openedUpstream = false
    private var endedDirections = 0

    init(id: UUID, client: NWConnection, route: RelayRoute, relayPort: UInt16,
         queue: DispatchQueue, didClose: @escaping @Sendable (UUID) -> Void) {
        self.id = id
        self.client = client
        self.route = route
        self.relayPort = relayPort
        self.queue = queue
        self.didClose = didClose
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
        }
        client.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.streaming else { return }
            self.reject(504, "Gateway Timeout")
        }
        self.timeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        readHeader(client) { [weak self] header, remainder in
            guard let self, !self.closed else { return }
            do {
                let request = try RelayRequest.parse(header)
                guard !request.destination.isLocalRelay(port: self.relayPort) else {
                    self.reject(400, "Bad Request")
                    return
                }
                self.connect(request, clientRemainder: remainder)
            } catch {
                self.reject(400, "Bad Request")
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        timeout = nil
        client.stateUpdateHandler = nil
        upstream?.stateUpdateHandler = nil
        client.cancel()
        upstream?.cancel()
        didClose(id)
    }

    private func connect(_ request: RelayRequest, clientRemainder: Data) {
        let address: ProxyEndpoint
        switch route {
        case .direct: address = request.destination
        case .proxy(let endpoint): address = endpoint
        }
        let upstream = NWConnection(host: NWEndpoint.Host(address.host),
                                    port: NWEndpoint.Port(rawValue: address.port)!, using: .tcp)
        self.upstream = upstream
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                guard !self.openedUpstream else { return }
                self.openedUpstream = true
                if case .proxy = self.route {
                    self.openProxyTunnel(upstream, request: request, clientRemainder: clientRemainder)
                } else {
                    self.beginStreaming(request, clientRemainder: clientRemainder, upstreamRemainder: Data())
                }
            case .failed, .waiting:
                if self.streaming { self.close() } else { self.reject(502, "Bad Gateway") }
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func openProxyTunnel(_ upstream: NWConnection, request: RelayRequest, clientRemainder: Data) {
        // 先由 Clash 建立到目标的 TCP 隧道，再透传 TLS 或普通 HTTP 数据。
        let authority = request.destination.authority
        let header = Data("CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\r\n".utf8)
        send(header, to: upstream) { [weak self] in
            self?.readHeader(upstream) { [weak self] header, remainder in
                guard let self, !self.closed else { return }
                let statusLine = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                let parts = statusLine.split(separator: " ")
                guard parts.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[0])),
                      let status = Int(parts[1]), (200..<300).contains(status) else {
                    self.reject(502, "Bad Gateway")
                    return
                }
                self.beginStreaming(request, clientRemainder: clientRemainder, upstreamRemainder: remainder)
            }
        }
    }

    private func beginStreaming(_ request: RelayRequest, clientRemainder: Data, upstreamRemainder: Data) {
        guard !closed, let upstream else { return }
        streaming = true
        timeout?.cancel()
        timeout = nil
        let clientPrefix = request.isConnect ? clientRemainder : request.forwardedHeader + clientRemainder
        let begin: @Sendable () -> Void = { [weak self] in
            guard let self, !self.closed else { return }
            self.send(clientPrefix, to: upstream) { [weak self] in self?.pump(from: self?.client, to: upstream) }
            self.send(upstreamRemainder, to: self.client) { [weak self] in self?.pump(from: upstream, to: self?.client) }
        }
        if request.isConnect {
            send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), to: client, then: begin)
        } else {
            begin()
        }
    }

    private func readHeader(_ connection: NWConnection, buffer: Data = Data(),
                            then completion: @escaping @Sendable (Data, Data) -> Void) {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let boundary = buffer.range(of: RelayRequest.headerDelimiter) {
                guard boundary.upperBound <= RelayRequest.maximumHeaderSize else {
                    self.reject(431, "Request Header Fields Too Large")
                    return
                }
                completion(Data(buffer[..<boundary.lowerBound]), Data(buffer[boundary.upperBound...]))
            } else if buffer.count > RelayRequest.maximumHeaderSize {
                self.reject(431, "Request Header Fields Too Large")
            } else if complete || error != nil {
                self.reject(connection === self.client ? 400 : 502, "Bad Gateway")
            } else {
                self.readHeader(connection, buffer: buffer, then: completion)
            }
        }
    }

    private func send(_ data: Data, to connection: NWConnection, then completion: @escaping @Sendable () -> Void) {
        guard !closed else { return }
        if data.isEmpty { completion(); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil { self.close() } else { completion() }
        })
    }

    private func pump(from source: NWConnection?, to destination: NWConnection?) {
        guard !closed, let source, let destination else { return }
        // 写入完成后才读取下一块，避免慢连接导致无界内存增长。
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if error != nil { self.close(); return }
            if complete {
                destination.send(content: data, contentContext: .finalMessage, isComplete: true,
                                 completion: .contentProcessed { [weak self] _ in
                    guard let self, !self.closed else { return }
                    self.endedDirections += 1
                    if self.endedDirections == 2 { self.close() }
                })
            } else {
                self.send(data ?? Data(), to: destination) { [weak self] in self?.pump(from: source, to: destination) }
            }
        }
    }

    private func reject(_ status: Int, _ reason: String) {
        guard !closed, !rejecting else { return }
        if streaming { close(); return }
        rejecting = true
        timeout?.cancel()
        timeout = nil
        let response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        client.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close() })
    }
}

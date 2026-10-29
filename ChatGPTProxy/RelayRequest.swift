import Foundation

enum RelayRoute: Equatable, Sendable {
    case direct
    case proxy(ProxyEndpoint)
}

enum NetworkMode: String, CaseIterable, Sendable {
    case direct
    case proxy

    var title: String { self == .direct ? "直连" : "Clash 代理" }
}

struct RelayRequest: Sendable {
    let destination: ProxyEndpoint
    let isConnect: Bool
    let forwardedHeader: Data

    static let headerDelimiter = Data("\r\n\r\n".utf8)
    static let maximumHeaderSize = 64 * 1024

    static func parse(_ data: Data) throws -> RelayRequest {
        guard let text = String(data: data, encoding: .isoLatin1) else { throw invalidRequest }
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, isToken(String(parts[0])),
              ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[2])) else { throw invalidRequest }
        let method = String(parts[0])
        let target = String(parts[1])
        var headers: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw invalidRequest }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard isToken(name), !value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) else {
                throw invalidRequest
            }
            headers.append((name, value))
        }
        let lengths = headers.filter { $0.0.lowercased() == "content-length" }
        let encodings = headers.filter { $0.0.lowercased() == "transfer-encoding" }
        guard lengths.count <= 1, encodings.count <= 1,
              lengths.isEmpty || encodings.isEmpty else { throw invalidRequest }
        if let value = lengths.first?.1 {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  UInt64(value) != nil else { throw invalidRequest }
        }
        if let value = encodings.first?.1, value.lowercased() != "chunked" { throw invalidRequest }

        if method == "CONNECT" {
            guard let url = URLComponents(string: "http://" + target),
                  url.path.isEmpty, url.query == nil, url.fragment == nil,
                  let port = url.port else { throw invalidRequest }
            let endpoint = try endpoint(url, port: port)
            return RelayRequest(destination: endpoint, isConnect: true, forwardedHeader: Data())
        }

        guard let url = URLComponents(string: target), url.scheme?.lowercased() == "http",
              url.fragment == nil else { throw invalidRequest }
        let destination = try endpoint(url, port: url.port ?? 80)
        let path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        let originTarget = path + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        let upgrade = headers.contains { $0.0.lowercased() == "upgrade" }
            && headers.contains { $0.0.lowercased() == "connection" && $0.1.lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "upgrade" } }
        let removed: Set<String> = ["proxy-authorization", "proxy-connection", "connection", "keep-alive", "host"]
        var forwarded = "\(method) \(originTarget) HTTP/1.1\r\nHost: \(destination.authority)\r\n"
        for (name, value) in headers where !removed.contains(name.lowercased()) {
            forwarded += "\(name): \(value)\r\n"
        }
        // 普通 HTTP 每连接处理一个请求；WebSocket 升级后保持双向透传。
        forwarded += "Connection: \(upgrade ? "Upgrade" : "close")\r\n\r\n"
        guard let encoded = forwarded.data(using: .isoLatin1) else { throw invalidRequest }
        return RelayRequest(destination: destination, isConnect: false, forwardedHeader: encoded)
    }

    private static func endpoint(_ url: URLComponents, port: Int) throws -> ProxyEndpoint {
        guard url.user == nil, url.password == nil, let host = url.host else { throw invalidRequest }
        return try ProxySettings(host: host, port: String(port)).validated()
    }

    private static func isToken(_ string: String) -> Bool {
        !string.isEmpty && string.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || "!#$%&'*+-.^_`|~".utf8.contains($0)
        }
    }

    private static var invalidRequest: LauncherError { .message("无效的 HTTP 代理请求。") }
}

extension ProxyEndpoint {
    var authority: String { "\(host.contains(":") ? "[\(host)]" : host):\(port)" }

    func isLocalRelay(port: UInt16) -> Bool {
        self.port == port && (host.lowercased() == "localhost" || host == "::1" || host.hasPrefix("127."))
    }
}

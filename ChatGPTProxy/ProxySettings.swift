import Darwin
import Foundation

struct ProxySettings: Equatable, Sendable {
    var host: String
    var port: String

    func validated() throws -> ProxyEndpoint {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !portText.isEmpty,
              portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(portText), port > 0 else {
            throw LauncherError.message("请输入 1–65535 之间的代理端口。")
        }

        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else {
                throw LauncherError.message("IPv6 代理主机格式无效。")
            }
        } else {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard !host.isEmpty, host.utf8.count <= 253,
                  labels.allSatisfy({ label in
                      !label.isEmpty && label.utf8.count <= 63 &&
                      label.first != "-" && label.last != "-" &&
                      label.utf8.allSatisfy {
                          (48...57).contains($0) || (65...90).contains($0) ||
                          (97...122).contains($0) || $0 == 45
                      }
                  }) else {
                throw LauncherError.message("请输入代理主机名或 IP 地址，不要包含协议、端口或路径。")
            }
        }

        return ProxyEndpoint(host: host, port: port)
    }
}

struct ProxyEndpoint: Equatable, Sendable {
    let host: String
    let port: UInt16

    var proxyURL: String {
        let authority = host.contains(":") ? "[\(host)]" : host
        return "http://\(authority):\(port)"
    }
}

enum LauncherError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

import AppKit

struct LaunchConfiguration {
    let endpoint: ProxyEndpoint?

    var arguments: [String] {
        guard let endpoint else { return [] }
        // 保留 Chromium 默认的本地回环绕过规则。
        return ["--proxy-server=\(endpoint.proxyURL)"]
    }

    var environment: [String: String] {
        guard let endpoint else { return [:] }
        var result: [String: String] = [:]
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
            result[key] = endpoint.proxyURL
            result[key.lowercased()] = endpoint.proxyURL
        }
        result["NO_PROXY"] = "localhost,127.0.0.1,::1"
        result["no_proxy"] = result["NO_PROXY"]
        return result
    }

    @MainActor
    func workspaceConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.environment = environment
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        return configuration
    }
}

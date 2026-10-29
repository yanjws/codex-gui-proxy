import Foundation

@main
struct RelayTestDriver {
    static func write(_ value: String) {
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
    }

    static func main() async throws {
        let relay = ProxyRelay()
        let requestedPort = CommandLine.arguments.dropFirst().first.flatMap(UInt16.init)
        let endpoint = try await relay.start(port: requestedPort, route: .direct)
        write("READY \(endpoint.port)")
        while let command = readLine() {
            do {
                let parts = command.split(separator: " ")
                switch parts.first {
                case "direct":
                    let closed = try await relay.setRoute(.direct)
                    write("OK \(closed)")
                case "proxy":
                    let proxy = try ProxySettings(host: "127.0.0.1", port: String(parts[1])).validated()
                    let closed = try await relay.setRoute(.proxy(proxy))
                    write("OK \(closed)")
                case "normal":
                    let normal = LaunchConfiguration(endpoint: nil)
                    precondition(normal.arguments.isEmpty && normal.environment.isEmpty)
                    let config = normal.workspaceConfiguration()
                    precondition(config.arguments.isEmpty && config.environment.isEmpty)
                    write("OK")
                case "stop":
                    await relay.stop()
                    write("OK")
                    return
                default:
                    write("ERROR unknown command")
                }
            } catch { write("ERROR \(error.localizedDescription)") }
        }
        await relay.stop()
    }
}

import Foundation

@main
struct LauncherModelTestDriver {
    static func write(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    @MainActor
    static func main() async throws {
        let suite = CommandLine.arguments[1]
        let phase = CommandLine.arguments[2]
        let defaults = UserDefaults(suiteName: suite)!
        if phase == "seed" {
            let model = LauncherModel(defaults: defaults)
            await model.changeMode(.direct)
            precondition(model.mode == .direct && !model.isError)
            model.port = CommandLine.arguments[3]
            await model.changeMode(.proxy)
            precondition(model.mode == .proxy && !model.isError)
            let applied = model.appliedProxyEndpoint
            model.host = "invalid/path"
            model.settingsChanged()
            await model.changeMode(.proxy)
            precondition(model.isError && model.mode == .proxy && model.appliedProxyEndpoint == applied)
            defaults.synchronize()
            write("PASS failed apply retains prior route and saves draft separately")
        } else {
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = LauncherModel(defaults: defaults)
            precondition(model.host == "invalid/path" && model.mode == .proxy)
            await model.prepareRelay()
            precondition(!model.isError && model.relayEndpoint != nil)
            precondition(model.managedPID == nil && !model.needsQuitWarning)
            write("READY \(model.relayEndpoint!.port)")
            _ = readLine()
        }
    }
}

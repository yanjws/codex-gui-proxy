import AppKit

@MainActor
enum ApplicationLauncher {
    static func runningApplication(for target: TargetApplication) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleIdentifier)
            .first { !$0.isTerminated }
    }

    static func launch(_ target: TargetApplication, endpoint: ProxyEndpoint?) async throws -> NSRunningApplication {
        // 启动前重新校验，避免已更新或移动的应用沿用过期路径。
        let target = try ApplicationLocator.validate(target.url)
        guard runningApplication(for: target) == nil else {
            throw LauncherError.message("\(target.displayName) 已在运行。请先正常退出应用，再通过本启动器打开，代理设置才会生效。")
        }
        let configuration = LaunchConfiguration(endpoint: endpoint).workspaceConfiguration()
        return try await NSWorkspace.shared.openApplication(at: target.url, configuration: configuration)
    }

    static func quitNormally(_ target: TargetApplication) async throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleIdentifier)
            .filter { !$0.isTerminated }
        for application in applications {
            guard application.terminate() else {
                throw LauncherError.message("应用未接受退出请求，请先手动正常退出。未强制终止任何进程。")
            }
        }
        for _ in 0..<150 {
            if applications.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LauncherError.message("应用尚未退出，请处理应用中的提示后重试。未强制终止任何进程。")
    }
}

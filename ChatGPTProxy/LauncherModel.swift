import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class LauncherModel {
    var host: String
    var port: String
    private(set) var mode: NetworkMode
    private(set) var appliedProxyEndpoint: ProxyEndpoint?
    private(set) var target: TargetApplication?
    private(set) var relayEndpoint: ProxyEndpoint?
    private(set) var connectionCount = 0
    private(set) var managedPID: pid_t?
    private(set) var busy = false
    private(set) var status = "首次接入请退出 ChatGPT，再通过本工具启动。"
    private(set) var isError = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var savedPath: String
    @ObservationIgnored private var relay: ProxyRelay?
    @ObservationIgnored private var managedApplication: NSRunningApplication?

    var managesRunningApplication: Bool { managedApplication?.isTerminated == false }
    var needsQuitWarning: Bool { managesRunningApplication || connectionCount > 0 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        host = defaults.string(forKey: "proxyHost") ?? "127.0.0.1"
        port = defaults.string(forKey: "proxyPort") ?? ""
        mode = NetworkMode(rawValue: defaults.string(forKey: "networkMode") ?? "") ?? .proxy
        savedPath = defaults.string(forKey: "applicationPath") ?? ""
        appliedProxyEndpoint = try? ProxySettings(
            host: defaults.string(forKey: "appliedProxyHost") ?? host,
            port: defaults.string(forKey: "appliedProxyPort") ?? port
        ).validated()
        target = ApplicationLocator.locate(savedPath: savedPath)
        if let target { savedPath = target.url.path }
        let pid = pid_t(defaults.integer(forKey: "managedPID"))
        if pid > 0, let application = NSRunningApplication(processIdentifier: pid),
           !application.isTerminated, application.bundleIdentifier == target?.bundleIdentifier,
           application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == target?.url,
           let date = application.launchDate,
           abs(date.timeIntervalSince1970 - defaults.double(forKey: "managedLaunchDate")) < 0.01 {
            managedApplication = application
            managedPID = pid
        }
        if target == nil { status = "未找到支持的 ChatGPT 应用，请手动选择。" }
    }

    func save() {
        defaults.set(host, forKey: "proxyHost")
        defaults.set(port, forKey: "proxyPort")
        defaults.set(savedPath, forKey: "applicationPath")
        defaults.set(mode.rawValue, forKey: "networkMode")
    }

    func settingsChanged() {
        save()
        report("地址已保存，点击“应用代理地址”生效。")
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择 ChatGPT 应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let selected = try ApplicationLocator.validate(url)
            guard !managesRunningApplication || selected == target else {
                throw LauncherError.message("请先恢复普通启动或退出当前受管理的应用，再选择其他安装位置。")
            }
            target = selected
            savedPath = selected.url.path
            save()
            report("已选择 \(selected.displayName)。")
        } catch { report(error.localizedDescription, error: true) }
    }

    func prepareRelay() async {
        guard !busy, relayEndpoint == nil else { return }
        let restoredRoute: RelayRoute
        if mode == .direct {
            restoredRoute = .direct
        } else if let appliedProxyEndpoint {
            restoredRoute = .proxy(appliedProxyEndpoint)
        } else {
            return
        }
        busy = true
        defer { busy = false }
        do {
            _ = try await ensureRelay(route: restoredRoute)
            report(managesRunningApplication
                   ? "本机中转已恢复，ChatGPT 可重新连接。"
                   : "中转已就绪。请先退出 ChatGPT，再点击下方按钮接入。")
        } catch { report(error.localizedDescription, error: true) }
    }

    func changeMode(_ selected: NetworkMode) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let route = try route(for: selected)
            if case .proxy(let endpoint) = route {
                report("正在检查 Clash 代理端口…")
                try await ProxyPortChecker.check(endpoint)
            }
            _ = try await ensureRelay(route: route)
            recordAppliedRoute(route)
            mode = selected
            save()
            report(managesRunningApplication
                   ? "已应用\(selected.title)，线路变化后 ChatGPT 将重新连接。"
                   : "已选择\(selected.title)。请通过下方按钮启动 ChatGPT 以接入中转。")
        } catch { report(error.localizedDescription, error: true) }
    }

    func testPort() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let endpoint = try ProxySettings(host: host, port: port).validated()
            save()
            report("正在检查 Clash 代理端口…")
            try await ProxyPortChecker.check(endpoint)
            report("端口可连接：\(endpoint.proxyURL)。尚未验证代理协议和目标网站连通性。")
        } catch { report(error.localizedDescription, error: true) }
    }

    func launch() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard let target else { throw LauncherError.message("请先选择支持的 ChatGPT 应用。") }
            guard ApplicationLauncher.runningApplication(for: target) == nil else {
                throw LauncherError.message("\(target.displayName) 已在运行。首次接入中转需要先正常退出，再通过本工具启动；现有进程不会被自动接管。")
            }
            let route = try route(for: mode)
            if case .proxy(let endpoint) = route { try await ProxyPortChecker.check(endpoint) }
            let endpoint = try await ensureRelay(route: route)
            recordAppliedRoute(route)
            save()
            report("正在通过本机中转启动 \(target.displayName)…")
            let application = try await ApplicationLauncher.launch(target, endpoint: endpoint)
            managedApplication = application
            managedPID = application.processIdentifier
            defaults.set(Int(application.processIdentifier), forKey: "managedPID")
            defaults.set(application.launchDate?.timeIntervalSince1970 ?? 0, forKey: "managedLaunchDate")
            report("\(target.displayName) 已接入，当前为\(mode.title)，可直接切换线路。")
        } catch { report(error.localizedDescription, error: true) }
    }

    // 仅由界面中的“重启并恢复”确认按钮调用。
    func restoreNormalLaunch() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard let target else { throw LauncherError.message("请先选择支持的 ChatGPT 应用。") }
            let validated = try ApplicationLocator.validate(target.url)
            report("正在请求 ChatGPT 正常退出…")
            try await ApplicationLauncher.quitNormally(validated)
            clearManagedSession()
            report("正在恢复普通启动…")
            _ = try await ApplicationLauncher.launch(validated, endpoint: nil)
            await relay?.stop()
            relayEndpoint = nil
            report("已恢复普通启动，本机中转已停止。应用按自身及系统网络设置连接，不再注入本工具的代理配置。")
        } catch { report(error.localizedDescription, error: true) }
    }

    func refreshManagedSession() {
        if managedApplication?.isTerminated == true {
            clearManagedSession()
            report("ChatGPT 已退出。本机中转继续运行，可再次通过中转启动。")
        }
    }

    private func clearManagedSession() {
        managedApplication = nil
        managedPID = nil
        defaults.removeObject(forKey: "managedPID")
        defaults.removeObject(forKey: "managedLaunchDate")
    }

    private func route(for mode: NetworkMode) throws -> RelayRoute {
        mode == .direct ? .direct : .proxy(try ProxySettings(host: host, port: port).validated())
    }

    private func recordAppliedRoute(_ route: RelayRoute) {
        if case .proxy(let endpoint) = route {
            appliedProxyEndpoint = endpoint
            defaults.set(endpoint.host, forKey: "appliedProxyHost")
            defaults.set(String(endpoint.port), forKey: "appliedProxyPort")
        }
    }

    private func ensureRelay(route: RelayRoute) async throws -> ProxyEndpoint {
        if relay == nil {
            relay = ProxyRelay(connectionCountChanged: { [weak self] count in
                Task { @MainActor [weak self] in self?.connectionCount = count }
            }, failed: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.relayEndpoint = nil
                    self?.report(message, error: true)
                }
            })
        }
        guard let relay else { throw LauncherError.message("本机中转初始化失败。") }
        if let relayEndpoint {
            try await relay.setRoute(route)
            return relayEndpoint
        }
        let savedPort = UInt16(exactly: defaults.integer(forKey: "relayPort"))
        let endpoint = try await relay.start(port: savedPort == 0 ? nil : savedPort, route: route)
        relayEndpoint = endpoint
        defaults.set(Int(endpoint.port), forKey: "relayPort")
        return endpoint
    }

    private func report(_ message: String, error: Bool = false) {
        status = message
        isError = error
    }
}

import AppKit
import SwiftUI

struct MainView: View {
    @Bindable var model: LauncherModel
    @State private var confirmRestore = false
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            routeCard
            proxyCard
            applicationCard
            statusMessage
            actions
        }
        .padding(20)
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.blue)
        .disabled(model.busy)
        .onChange(of: model.host) { model.settingsChanged() }
        .onChange(of: model.port) { model.settingsChanged() }
        .task { await model.prepareRelay() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            model.refreshManagedSession()
        }
        .alert("恢复普通启动需要重启 ChatGPT", isPresented: $confirmRestore) {
            Button("取消", role: .cancel) {}
            Button("重启并恢复", role: .destructive) { Task { await model.restoreNormalLaunch() } }
        } message: {
            Text("将请求 ChatGPT 正常退出，再按应用自身及系统网络设置启动。正在生成的回复和运行中的任务可能中断；如果应用拒绝退出，将停止操作，不会强制结束进程。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("ChatGPT Proxy")
                    .font(.system(size: 21, weight: .semibold))
                Text("为 ChatGPT 选择连接方式")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(model.managedPID == nil ? Color.secondary : Color.green)
                    .frame(width: 6, height: 6)
                Text(model.managedPID == nil ? "待接入" : "已接入")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .help("表示 ChatGPT 是否由本工具的中转管理，不代表互联网连通性。")
        }
    }

    private var routeCard: some View {
        card {
            HStack {
                Text("连接方式").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.relayEndpoint != nil {
                    Text("\(model.connectionCount) 个活跃连接")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Picker("网络线路", selection: Binding(get: { model.mode }, set: { selected in
                Task { await model.changeMode(selected) }
            })) {
                ForEach(NetworkMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.large)
            .accessibilityLabel("网络线路")
            HStack(spacing: 6) {
                Image(systemName: model.mode == .direct ? "arrow.up.right" : "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.blue)
                Text(model.mode == .direct ? "经本机中转直连，不经过 Clash" : "经本机中转连接 Clash 代理")
                Spacer(minLength: 4)
                Text("切换会短暂重连")
                Image(systemName: "info.circle")
                    .help("线路变化会断开旧连接，正在生成的回复或任务可能中断。系统代理和 TUN 保持原有设置。")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var proxyCard: some View {
        card {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Clash 主机").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("127.0.0.1", text: $model.host)
                        .accessibilityLabel("代理主机")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("HTTP / Mixed 端口").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("HTTP / Mixed", text: $model.port)
                        .accessibilityLabel("代理端口")
                }
                .frame(width: 104)
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            HStack(spacing: 8) {
                Text(model.appliedProxyEndpoint.map { "已应用 \($0.authority)" } ?? "填写 Clash 的 HTTP / Mixed 端口")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.appliedProxyEndpoint?.proxyURL ?? "地址修改后需要点击应用。")
                Spacer(minLength: 0)
                Button("测试端口") { Task { await model.testPort() } }
                    .controlSize(.small)
                Button("应用代理地址") { Task { await model.changeMode(.proxy) } }
                    .controlSize(.small)
            }
        }
    }

    private var applicationCard: some View {
        card {
            HStack(spacing: 9) {
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                Text(model.target?.displayName ?? "尚未选择应用")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("选择应用…") { model.chooseApplication() }
                    .controlSize(.small)
            }
            DisclosureGroup("连接详情", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    detail("本机中转", model.relayEndpoint?.proxyURL ?? "尚未启动")
                    detail("当前 Clash", model.appliedProxyEndpoint?.proxyURL ?? "尚未配置")
                    detail("应用位置", model.target?.url.path ?? "尚未选择")
                    detail("ChatGPT 进程", model.managedPID.map { String($0) } ?? "尚未接入中转")
                    Text("作用于整个 ChatGPT 应用，包括 Chat、Work 和 Codex。首次接入中转需正常退出 ChatGPT 后，通过本工具启动。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 9)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var statusMessage: some View {
        HStack(alignment: .top, spacing: 8) {
            if model.busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: model.isError ? "exclamationmark.circle.fill" : "info.circle.fill")
                    .foregroundStyle(model.isError ? Color.red : Color.blue)
            }
            Text(model.status)
                .font(.system(size: 12))
                .foregroundStyle(model.isError ? Color.red : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10).fill((model.isError ? Color.red : Color.blue).opacity(0.06)))
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                Task { await model.launch() }
            } label: {
                Label(model.managedPID == nil ? "通过中转启动 ChatGPT" : "ChatGPT 已接入中转",
                      systemImage: model.managedPID == nil ? "play.fill" : "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.managedPID != nil)
            HStack {
                Label("关闭窗口后继续运行", systemImage: "menubar.dock.rectangle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复普通启动…") { confirmRestore = true }
                    .buttonStyle(.link)
                    .disabled(model.target == nil)
                    .help("需要正常退出并重启 ChatGPT；退出本机中转模式。")
            }
            .font(.system(size: 11))
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11, content: content)
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1))
    }
}

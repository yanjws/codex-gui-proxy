import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: LauncherModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true {
            let alert = NSAlert()
            alert.messageText = "操作正在进行"
            alert.informativeText = "请等待当前操作结束后再退出。关闭窗口不会停止中转服务。"
            alert.addButton(withTitle: "保持运行")
            alert.runModal()
            return .terminateCancel
        }
        guard model?.needsQuitWarning == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "退出将停止本机中转"
        alert.informativeText = "正在使用中转的 ChatGPT 会失去这条网络连接。可先恢复普通启动，或关闭窗口让服务继续运行。"
        alert.addButton(withTitle: "保持运行")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.identifier?.rawValue == "launcher" }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

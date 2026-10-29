import SwiftUI

@main
struct ChatGPTProxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = LauncherModel()

    var body: some Scene {
        Window("ChatGPT Proxy", id: "launcher") {
            MainView(model: model)
                .onAppear { appDelegate.model = model }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

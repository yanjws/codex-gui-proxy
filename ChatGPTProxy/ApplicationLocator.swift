import AppKit

struct TargetApplication: Equatable, Sendable {
    let url: URL
    let bundleIdentifier: String
    let displayName: String
}

@MainActor
enum ApplicationLocator {
    // 合并后的 ChatGPT 桌面应用沿用 Codex 的 Bundle ID。
    static let bundleIdentifier = "com.openai.codex"

    static func validate(_ url: URL) throws -> TargetApplication {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              bundle.bundleIdentifier == bundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LauncherError.message("请选择支持的 ChatGPT 桌面应用（或原 Codex 应用），并确认应用安装完整。")
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return TargetApplication(url: url, bundleIdentifier: bundleIdentifier, displayName: name)
    }

    static func locate(savedPath: String) -> TargetApplication? {
        var candidates: [URL] = []
        if !savedPath.isEmpty {
            candidates.append(URL(fileURLWithPath: savedPath))
        }
        candidates += NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .compactMap(\.bundleURL)
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            candidates.append(registered)
        }
        for directory in [URL(fileURLWithPath: "/Applications", isDirectory: true),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            candidates += ["ChatGPT.app", "Codex.app"].map { directory.appendingPathComponent($0) }
        }
        return candidates.lazy.compactMap { try? validate($0) }.first
    }
}

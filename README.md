# codex-gui-proxy

A native macOS launcher that starts the unified ChatGPT desktop app with a local HTTP proxy. The original Shell launcher remains available for legacy Codex installations.

An independent utility, not an official OpenAI application.

[中文文档](README_CN.md)

## Native app

To build a Universal (arm64 + x86_64) drag-and-drop disk image, run `bash scripts/package-dmg.sh`. The result is `dist/ChatGPT-Proxy.dmg`; open it and drag **ChatGPT Proxy.app** into **Applications**. The package script builds in a temporary directory and verifies the mounted image before cleaning up its temporary app registrations. It uses local ad-hoc signing; Developer ID signing and notarization remain separate steps. Intel runtime behavior has not been verified on physical hardware.

Requires macOS 14+ and Xcode 16+ to build. No third-party dependencies.

```bash
xcodebuild -project ChatGPTProxy.xcodeproj \
  -scheme ChatGPTProxy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

The local build is `build/DerivedData/Build/Products/Debug/ChatGPT Proxy.app`. Alternatively, open `ChatGPTProxy.xcodeproj` in Xcode and run the `ChatGPTProxy` scheme. This build command produces an unsigned local app; distribution signing and notarization are separate steps.

For a local Release build with ad-hoc signing:

```bash
xcodebuild -project ChatGPTProxy.xcodeproj \
  -scheme ChatGPTProxy -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Release CODE_SIGN_IDENTITY=- build
```

The app is `build/Release/Build/Products/Release/ChatGPT Proxy.app`. Release strips debug symbols; any generated dSYM remains outside the app. Ad-hoc signing is for local use and does not provide Developer ID notarization.

1. Open **ChatGPT Proxy**. It locates the installed app automatically; use **选择应用…** to choose another installation.
2. Enter your Clash HTTP / Mixed Port and host, then select **Clash 代理** and use **测试端口** to check TCP connectivity. Alternatively select **直连**, which does not require Clash.
3. Quit ChatGPT normally once, then choose **通过中转启动 ChatGPT**. Existing ChatGPT processes are never silently taken over.
4. While ChatGPT is running through the relay, switch **直连 / Clash 代理** without restarting ChatGPT. A route change closes existing relay connections; ChatGPT must reconnect and an in-progress reply or task may be interrupted. Applying an unchanged route leaves existing connections intact.
5. Editing the Clash address saves a draft. Choose **应用代理地址** to validate and apply it. If validation fails, the previous route stays active. The displayed current Clash address identifies the applied configuration.
6. **恢复普通启动…** asks for confirmation, requests a normal ChatGPT exit, and relaunches it without this tool's arguments or proxy environment. This operation requires a ChatGPT restart; if it refuses to exit or times out, no force quit occurs.

Closing the window keeps the relay running. Click the Dock icon to reopen the window. Quitting the utility stops its relay; a confirmation is shown if ChatGPT is managed by the relay or connections are active. Ordinary ChatGPT startup remains available through its original app icon.

Host, port, selected route and app path are saved locally using UserDefaults. The loopback relay port is allocated on first use and reused on subsequent launches. If that port is occupied, startup reports an error rather than silently changing the endpoint that ChatGPT expects. Successfully applied proxy settings are stored separately from drafts so a failed edit does not break restoration.

## Connection modes

```text
ChatGPT → local relay on 127.0.0.1
                  ├─ Direct → destination
                  └─ Clash  → configured HTTP / Mixed proxy → destination
```

Both runtime modes require the local relay to keep running. Direct mode bypasses Clash but still passes through the local relay. To remove the relay from ChatGPT's network path entirely, use ordinary startup, which requires restarting ChatGPT. Ordinary startup follows the app's own and the system's network settings; it does not force a direct connection if a system proxy or TUN is enabled.

## Proxy scope

The target is the entire unified ChatGPT desktop app, including Chat, Work and Codex. The supported app retains the `com.openai.codex` bundle identifier; the executable is resolved from its bundle metadata instead of assuming it is named `Codex`.

ChatGPT is configured to connect to the local relay endpoint:

```text
--proxy-server=http://127.0.0.1:RELAY_PORT

HTTP_PROXY / http_proxy   = http://127.0.0.1:RELAY_PORT
HTTPS_PROXY / https_proxy = http://127.0.0.1:RELAY_PORT
ALL_PROXY / all_proxy     = http://127.0.0.1:RELAY_PORT
NO_PROXY / no_proxy       = localhost,127.0.0.1,::1
```

The upstream HTTP / Mixed port is used via HTTP CONNECT, while HTTPS/TLS remains opaque to this tool. The relay binds only to 127.0.0.1 and never records request URLs, content or credentials. Plain HTTP requests use one upstream request per connection; CONNECT and WebSocket upgrades use streaming tunnels. Proxy authentication, SOCKS-only ports, PAC and multiple profiles are outside the native app's current scope.

The loopback listener has no client authentication: other local processes can also connect to it. It does not provide isolation between local users or applications. Connection establishment, including an upstream CONNECT handshake, has a 10-second timeout; a timeout returns HTTP 504. Switching routes can interrupt active requests, and successful reconnection does not guarantee uninterrupted sessions.

Only applications launched through this utility receive these settings; subprocesses that inherit them may also use the proxy. The launcher does not change system proxy settings, TUN, shell startup files or the global launchctl environment. It does not change other independently launched applications.

An unavailable Clash proxy causes an error; the relay does not silently fall back to direct mode. A listening TCP port and a successful application launch do not prove that every request is proxied. Chromium requests and backend services must be checked separately; individual tools may use their own networking configuration. This launcher is not a network firewall or a traffic interception service.

Chromium's default localhost bypass is preserved. `<-loopback>` would remove that bypass and is intentionally omitted. See the [Chromium proxy documentation](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md#overriding-the-implicit-bypass-rules) and [Electron proxy switch documentation](https://www.electronjs.org/docs/latest/api/command-line-switches#--proxy-serveraddressport).

App Sandbox is disabled because AppKit ignores the requested launch arguments for sandboxed callers. The target application's bundle is not modified or re-signed.

## Validation

Run `bash scripts/test-relay.sh` on macOS with Xcode and Python 3. The tests use loopback fixtures to cover direct/proxy routing, live switching, CONNECT streaming, early tunnel data, HTTP bodies, WebSocket upgrades, half-closes, upstream failures, malformed requests, port reuse and configuration restoration. They do not restart the real ChatGPT app.

## Legacy Shell launcher

`codex-proxy.sh` still targets `/Applications/Codex.app/Contents/MacOS/Codex` by default. For a different executable, configure `CODEX_APP_PATH` in the environment or a configuration file. The native app does not execute this script or import its configuration files.

```bash
bash codex-proxy.sh --proxy-url http://127.0.0.1:PORT
```

Replace `PORT` with your actual port. The script's historical fallback is `7898`; it is not a universal Clash default. See `codex-proxy-launcher.env.example` for supported configuration keys. The Shell launcher warns about unavailable ports but still attempts to start; the native app blocks startup on a failed port check.

The paired `codex-proxy-solution` and `macOS-PerApp-Proxy` articles describe the original approaches. Use this README for the current native app's behavior and limits.

## License

[MIT](LICENSE). Original copyright attribution is retained, and LICENSE is included in the native app's resources.

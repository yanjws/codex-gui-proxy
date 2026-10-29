# codex-gui-proxy

原生 macOS 代理启动器，通过本地 HTTP 代理启动整合后的 ChatGPT 桌面应用。原有 Shell 启动器保留，供旧版 Codex 安装使用。

本工具为独立项目，并非 OpenAI 官方应用。

[English](README.md)

## 原生应用

运行 `bash scripts/package-dmg.sh` 可生成 Universal（arm64 + x86_64）拖拽安装镜像 `dist/ChatGPT-Proxy.dmg`。打开后，将 **ChatGPT Proxy.app** 拖入 **Applications** 即可安装。脚本在临时目录构建，挂载核验镜像后清理临时应用注册，不保留额外启动入口。镜像使用本地临时签名，Developer ID 签名和公证另行处理。Intel 版本尚未经实机运行验证。

需要 macOS 14+，使用 Xcode 16+ 构建，无第三方依赖。

```bash
xcodebuild -project ChatGPTProxy.xcodeproj \
  -scheme ChatGPTProxy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

本地构建产物为 `build/DerivedData/Build/Products/Debug/ChatGPT Proxy.app`。也可以在 Xcode 中打开 `ChatGPTProxy.xcodeproj`，运行 `ChatGPTProxy` Scheme。上述命令生成未签名的本地应用；对外分发所需的签名、公证另行处理。

使用本地临时签名构建 Release：

```bash
xcodebuild -project ChatGPTProxy.xcodeproj \
  -scheme ChatGPTProxy -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Release CODE_SIGN_IDENTITY=- build
```

产物为 `build/Release/Build/Products/Release/ChatGPT Proxy.app`。Release 会剥离调试符号，生成的 dSYM 保留在应用包外。本地临时签名用于本机运行，不代表已完成 Developer ID 签名或公证。

1. 打开 **ChatGPT Proxy**，自动定位已安装的应用；也可通过 **选择应用…** 指定其他安装位置。
2. 填写 Clash 实际的 HTTP / Mixed Port 和主机，选择 **Clash 代理**，可用 **测试端口** 检查 TCP 连通性。也可选择 **直连**，此模式不依赖 Clash。
3. 首次接入中转时，正常退出 ChatGPT，再点击 **通过中转启动 ChatGPT**。已经运行的 ChatGPT 不会被静默接管。
4. ChatGPT 经中转启动后，可切换 **直连 / Clash 代理**，无需重启 ChatGPT。线路变化会关闭旧连接，应用需要重新连接，进行中的回复或任务可能中断。重复应用相同线路不会断开已有连接。
5. 修改 Clash 地址只保存草稿，点击 **应用代理地址** 才会检查并应用。检查失败时保留原线路；“当前 Clash 地址”显示实际已应用的配置。
6. **恢复普通启动…** 会先弹出确认提示，再请求 ChatGPT 正常退出，并在不注入本工具启动参数及代理环境的情况下重新打开。此操作需要重启 ChatGPT；如果应用拒绝退出或超时，不会强制结束进程。

关闭窗口后，中转服务继续运行；点击 Dock 图标可以重新显示窗口。退出本工具会停止中转；如果 ChatGPT 由中转管理或仍有活跃连接，会先提示确认。仍可通过 ChatGPT 原来的图标普通启动。

主机、端口、所选线路及应用路径通过 UserDefaults 保存在本机。中转端口首次自动分配，后续沿用；端口被占用时会明确报错，不会静默换端口，避免 ChatGPT 继续连接旧地址。已应用代理配置与编辑草稿分开保存，失败的修改不会破坏配置恢复。

## 两种网络线路

```text
ChatGPT → 127.0.0.1 上的本机中转
                  ├─ 直连 → 目标服务
                  └─ Clash 代理 → 配置的 HTTP / Mixed 代理 → 目标服务
```

两种线路都需要本机中转持续运行。直连不经过 Clash，但仍经过本机中转；要完全移除中转，需要恢复普通启动并重启 ChatGPT。普通启动遵循应用自身及系统网络设置，如果系统代理或 TUN 已开启，不代表一定直连。

## 代理范围

目标是整个 ChatGPT 桌面应用，包括 Chat、Work 和 Codex。受支持的整合版应用沿用 `com.openai.codex` Bundle ID；启动器通过 Bundle 元数据处理应用，不再假定可执行文件名为 `Codex`。

向 ChatGPT 注入的是本机中转地址：

```text
--proxy-server=http://127.0.0.1:中转端口

HTTP_PROXY / http_proxy   = http://127.0.0.1:中转端口
HTTPS_PROXY / https_proxy = http://127.0.0.1:中转端口
ALL_PROXY / all_proxy     = http://127.0.0.1:中转端口
NO_PROXY / no_proxy       = localhost,127.0.0.1,::1
```

上游 HTTP / Mixed 端口通过 HTTP CONNECT 使用；HTTPS/TLS 数据透传，本工具不解密。中转只绑定 127.0.0.1，不记录请求地址、正文或认证信息。普通 HTTP 每连接转发一个请求，CONNECT 及 WebSocket 升级后保持流式隧道。原生应用暂不支持代理认证、仅 SOCKS 端口、PAC 或多配置切换。

回环监听不验证客户端身份，其他本机进程也能连接，不提供本机用户或应用之间的访问隔离。建立连接（包括上游 CONNECT 握手）有 10 秒超时，超时返回 HTTP 504。切换线路可能中断正在进行的请求，重连成功不代表会话全程无中断。

这些配置仅传给新启动的应用；继承环境变量的子进程也可能使用代理。启动器不修改系统代理、TUN、Shell 启动文件或全局 launchctl 环境，不改变其他独立启动应用的代理配置。

Clash 不可用时会返回错误，不会静默降级为直连。TCP 端口可连接和应用启动成功，均不能证明所有请求都经过代理。需要分别检查 Chromium 请求与内部服务；个别工具可能使用自己的网络配置。本工具不提供防火墙或流量劫持功能。

保留 Chromium 默认的本地回环绕过规则。`<-loopback>` 会移除这些默认规则，因此不传入。参见 [Chromium 代理文档](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md#overriding-the-implicit-bypass-rules) 和 [Electron 代理参数文档](https://www.electronjs.org/docs/latest/api/command-line-switches#--proxy-serveraddressport)。

App Sandbox 关闭，因为 AppKit 会忽略沙盒调用方传入的应用启动参数。启动器不修改或重新签名目标应用。

## 验证

在安装 Xcode 与 Python 3 的 macOS 上运行 `bash scripts/test-relay.sh`。测试使用本机回环服务，覆盖直连／代理路由、实时切换、CONNECT 透传、隧道预读数据、HTTP 请求体、WebSocket 升级、半关闭、上游失败、无效请求、端口复用及配置恢复，不会重启真实 ChatGPT 应用。

## 原有 Shell 启动器

`codex-proxy.sh` 默认仍定位 `/Applications/Codex.app/Contents/MacOS/Codex`。其他安装可在环境变量或配置文件中设置 `CODEX_APP_PATH` 指向实际可执行文件。原生应用不调用此脚本，也不导入其配置文件。

```bash
bash codex-proxy.sh --proxy-url http://127.0.0.1:端口
```

请替换为实际端口。脚本历史默认端口为 `7898`，不代表 Clash 的通用默认值。配置项见 `codex-proxy-launcher.env.example`。Shell 启动器在端口不可用时只警告并继续尝试启动；原生应用则会阻止本次启动。

双语 `codex-proxy-solution` 和 `macOS-PerApp-Proxy` 文章保留了原有方案说明。当前原生应用的使用方式和能力边界以本 README 为准。

## 协议

[MIT](LICENSE)。保留原项目版权归属，原生应用资源中包含 LICENSE。

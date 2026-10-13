# RemoteTool iOS 调试版

把 `app/mobile`（Kotlin + Jetpack Compose + Java 原生远控模块）原样移植成的 iOS 原生客户端。
**服务端零改动**：所有接口、请求体、Cookie 语义与 Android 版逐字对齐，可与现有
`/WebApplication`（.NET 8）直接互操作。

- 上游基线：`versionName 0.3.36 / versionCode 39`，`applicationId com.chuckiehelper.mobile`
- 本工程 Bundle ID：Debug `com.chuckiehelper.mobile.dev`、Release `com.chuckiehelper.mobile.ios`
- 部署目标：**iOS 16.0**（`URLSessionWebSocketTask` / `async-await` / `NavigationStack` /
  `AVSampleBufferDisplayLayer` 的下限）
- 需求来源：`docs/ios-debug-app-spec.md`

---

## 一、目录结构

```
ios/
├─ RemoteTooliOS.xcodeproj/          # 手写工程（objectVersion 77，用文件系统同步组，新增文件无需改工程）
├─ project.yml                       # XcodeGen 备用定义，二选一
├─ Config/
│  ├─ RemoteTooliOS-Info.plist       # Release：ATS 只放开局域网
│  └─ RemoteTooliOS-Info-Debug.plist # Debug：NSAllowsArbitraryLoads=true
└─ RemoteTooliOS/
   ├─ App/          RemoteToolApp / RootView / DevicesScreen / LoginScreen / HomeScreen
   ├─ Core/         NativeApi / DeviceStore / DeviceCipher / DeviceCredentialStore /
   │                DeviceAuthentication / NativeModel / Models / JSON / Gzip /
   │                StreamBuffer / WebSocketSupport / DebugOverrides
   ├─ Remote/       RemoteControlScreen / RemoteController / StreamingSession /
   │                H264StreamClient / VideoToolboxDecoder / VideoStageView /
   │                MjpegStreamClient / InputChannel / TouchSurfaceView / RemoteSurface /
   │                RelativeMotionQueue / RemoteQuality
   ├─ Screens/      SystemScreen / SystemDetailsView / ProcessesScreen / TerminalScreen /
   │                FilesScreen / DockerScreen（含 ComposeScreen）/ JobsScreen / AgentScreen
   ├─ Components/   CommonViews / Sheets
   └─ Debug/        RemoteToolDebugPanel（整个文件包在 `#if DEBUG` 内）
```

### 与规格文档「五、模块清单」的对应关系

规格里按功能列了 20+ 个文件，实现时做了合并，**能力一一对应，只是文件名不同**：

| 规格中的名字 | 实际实现 |
|---|---|
| `DeviceAuth.swift` + `ChannelSelector.swift` | `Core/DeviceAuthentication.swift`（`DeviceAuthentication` + `DeviceAddressSelection`） |
| `CodexScreen.swift` / `HermesScreen.swift` | `Screens/AgentScreen.swift`（同一套 REST + SSE，用 `agent` 参数区分，与 Android `HermesModel.kt` 一致） |
| `MoreScreen.swift` | `App/HomeScreen.swift` 里的 `moreList(api:)` |
| `VideoDisplayLayer.swift` | `Remote/VideoStageView.swift`（`AVSampleBufferDisplayLayer` + 图片层 + 缩放平移几何） |
| `TouchMapper.swift` + `MotionQueue.swift` | `Remote/TouchSurfaceView.swift` + `Remote/RelativeMotionQueue.swift` |
| `MjpegFallbackClient.swift` | `Remote/MjpegStreamClient.swift` |
| `RemoteToolDebugPanel.swift` | `Debug/RemoteToolDebugPanel.swift`（已实现，含基址覆盖 / 明文开关 / 画质覆盖 / 强制 MJPEG / 实时指标） |

---

## 二、构建与运行

### 真机（唯一可用的方式）

```bash
open ios/RemoteTooliOS.xcodeproj      # 选 RemoteTooliOS target → 真机 → Run
```

**模拟器不可用**：没有硬件解码路径、没有真实触控与系统输入法，远控功能无法验证。
所以 Debug 配置的 `CODE_SIGN_STYLE=Automatic`、`DEVELOPMENT_TEAM` 为空，第一次打开请先在
Xcode 的 Signing & Capabilities 里选自己的开发团队。

### 用 XcodeGen 重新生成工程（可选）

```bash
brew install xcodegen && cd ios && xcodegen generate
```

生成结果与仓库内工程等价（Debug 用 `Config/RemoteTooliOS-Info-Debug.plist`，
Release 用 `Config/RemoteTooliOS-Info.plist`）。

### 两个配置的差异（只有这两处）

| | Debug | Release |
|---|---|---|
| Bundle ID | `com.chuckiehelper.mobile.dev` | `com.chuckiehelper.mobile.ios` |
| ATS | `NSAllowsArbitraryLoads = true`（可直连 `http://192.168.x.x:5104`） | 只有 `NSAllowsLocalNetworking`，明文被系统拒绝 |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `DEBUG` | 无（调试面板、基址覆盖、协议版本提示全部不编译） |

---

## 三、调试面板

Debug 构建下，`RootView` 会读取 `debug.autoOpenPanel` 决定是否冷启动就弹出面板。
关闭时也可以在设备列表 / 主页走「更多」，或直接在 SwiftUI 预览里打开 `RemoteToolDebugPanel`。

面板能力：

1. **基址覆盖** —— 把请求 origin 改写成另一个地址，路径与查询串不变。
   语义就是「让 App 以为某设备在另一个地址上」，用来验证「新地址是不是同一台机器」。
   改完需要重新连接设备才生效（`DebugOverrides.apply(base:)`，Release 下是恒等函数）。
2. **端点身份查询** —— 直接打一次匿名 `/api/device/identity`，显示 `id` 前 16 位与
   `protocolVersion`，用来确认当前基址到底是谁。
3. **允许明文 / 强制 MJPEG** —— 前者让「只填 `192.168.x.x:5104`」也能自动补 `http://`；
   后者跳过 H.264 直接走 `/api/stream/legacy`，省掉一次注定失败的解码尝试。
4. **画质参数覆盖** —— 整体改写 `/api/stream` 的查询串，用来验证服务端 `StreamController`
   的白名单边界（`resolution` / `bitrate` / `maxrate` / `fps` / `crf` / `colors` / `format`）。
5. **实时指标** —— 收字节 / 渲染帧 / 最后出帧时刻 / 采集方式 / 解码路径 / 键鼠 ack 支持情况，
   数据源是 `RemoteDiagnostics`（`RemoteController` 每 1 秒发布一次快照）。
6. **网络日志开关** —— 开关本身只落在 `UserDefaults`，Cookie / `access_token` 一律脱敏，不写文件。

---

## 四、协议契约（与 Android 完全一致的关键点）

| 项 | 约定 |
|---|---|
| JSON 信封 | `System` / `Files` 控制器返回 `{success, message, data}`；`Docker` / `NativeJobs` 返回裸 `{data: ...}`。客户端两种都容忍 |
| 认证 | `POST /api/auth/login` 返回 `{token, username}` 并 `Set-Cookie: access_token`。401 → `LoginRequired` → 推回登录页 |
| 端点身份 | 只有 `/api/device/identity` 匿名；发送任何凭据**之前**必须先校验它，64 位小写十六进制指纹不匹配就拒绝 |
| 下行动画 | `GET /api/stream?format=h264`（`video/h264`，Annex B，`-bsf:v h264_metadata=aud=insert` 保证 AUD 边界）；回退 `GET /api/stream/legacy`（`multipart/x-mixed-replace`） |
| 采集方式 | 响应头 `X-Capture-Method`：`ddagrab`（DXGI 零拷贝）/ `gdigrab` |
| 上行输入 | `GET /ws/input` WebSocket 优先；`/api/input/*` HTTP 兜底 |
| 输入确认 | 请求带 `"ack": true` 时服务端回 `{"type":"input-ack","ok":true}`。`mouse-relative` 的 `dx=dy=0` 服务端直接返回、不合成鼠标动作 |
| 终端 | `GET /ws/terminal?type=shell\|powershell\|cmd`，**按行输入协议，不是 PTY**（`/bin/bash -i`），所以 vim 这类全屏程序不能指望 |
| 任务 | `GET /api/native-jobs/overview` → `{stats, servers, queues, recurring}`；`jobs` → `{data}`；`jobs/{id}/console` → `{data, attempt, nextOffset, total, hasMore, reset}` |
| Agent | `POST /api/{codex\|hermes}/runs` 必须带 `Idempotency-Key`；`delivery=rejected\|unknown` 时不能当成功；事件流走 `GET /api/{agent}/runs/{id}/events` 的 SSE |
| 请求压缩 | 服务端用 `X-RemoteTool-Request-Compression: gzip` 声明支持；只有声明过的 origin 才启用以避免打到旧服务端 |
| 重定向 | 全局禁止跟随（`NoRedirectDelegate`），避免把带 token 的请求发到未知主机 |

### iOS 侧的三处「不能照搬」，都写在代码注释里

1. **WebSocket 的 Cookie 必须显式放在请求头。**
   `URLSessionWebSocketTask` 不会自动附加 `HTTPCookieStorage` 里的 cookie（长期存在的平台行为）。
   我们也不用服务端支持的 `?access_token=` 查询串 —— 那会把长期有效的 token 写进反代日志。
2. **无限流不能用 `await session.data(for:)`。**
   会把整个响应读进内存，远程桌面几秒内就爆。必须走 `URLSessionDataDelegate` 逐块消费
   （`Remote/StreamingSession.swift`），并做首包校验（状态码 + Content-Type）以便快速失败回退。
3. **远控画面绝不能用 `AVPlayer`。**
   它自带播放缓冲，延迟会到秒级。正确路径是 `VTDecompressionSession` →
   `AVSampleBufferDisplayLayer` + `DisplayImmediately`，中间不落任何缓冲。

---

## 五、与 Android 的已知差异（有意为之）

| 项 | Android | iOS | 原因 |
|---|---|---|---|
| ack 能力探测 | 读握手响应头 `X-Chuckie-Input-Ack` | 主动发 `mouse-relative dx=0 dy=0 ack=true` 探测 | `URLSessionWebSocketTask` 不暴露握手响应头；服务端对这条命令短路返回，不会真的移鼠标 |
| 输入线程模型 | 单线程 `ExecutorService` 串行 | `Task` 链串行（`enqueueInput`） | 同样的「按下 / 移动 / 抬起 不乱序」语义 |
| ack 等待 | `CountDownLatch` | 1.5 ms 轮询 | 同一时刻只有一条相对位移在途，轮询延迟远小于一次网络往返，且避免 continuation 泄漏 |
| 明文放行 | 清单里 `usesCleartextTraffic=true` | 只在 Debug 的 ATS 里放开 | iOS 平台要求，Release 必须收紧 |
| 协议版本 | 不校验 | Debug 下提示、Release 静默（与 Android 一致） | 满足验收清单第 3 项又不改变正式版行为 |

### 尚未实现（不影响互操作性验证）

- Codex / Hermes：消息编辑、回退（rewind）、分叉（fork）、插话（steer）、置顶、
  离线队列、附件上传。这些全部建立在同一套 REST + SSE 契约上。
- 二维码扫码添加设备（规格里 Release 用不到）。
- 后台保活：iOS 没有 `FOREGROUND_SERVICE` 等价物，只能依赖前台运镜 + 断流自动重连。

---

## 六、验收清单（对照 `docs/ios-debug-app-spec.md` 第九节）

- [x] 与正式 Android 版并存安装，配置互不干扰 —— Bundle ID 加 `.dev`，`UserDefaults` / Keychain
      都是独立容器
- [x] LAN / IPv6 / 域名 / VPN 四类地址均可连，跨设备地址被正确拒绝 —— `DeviceAddressSelection`
      逐个探测身份，不匹配即列入失败
- [x] `protocolVersion` 校验生效 —— Debug 构建下 `probe` 会提示「未声明 protocolVersion」
- [x] H.264 硬解出画，`X-Capture-Method` 能区分 `ddagrab` / `gdigrab` —— 见调试面板「采集方式」
- [x] 解码失败自动回退 `/api/stream/legacy` 并给可见提示 —— 状态栏显示「MJPEG 兼容模式」
- [x] 实时指标与服务端行为一致 —— 每 1 秒刷新，字节数与服务端推流字节同源
- [x] 画面无延迟累积，切换画质档位后连接正确重建 —— `DropFrameWhenNotReady` + `RealTime`，
      切档位走 `selectQuality → reconnect`
- [x] 明文 http 直连可用（Debug）；Release 配置下明文被拒 —— 两个 Info.plist 分开管
- [x] 桌面切换导致的停流可自动恢复 —— 6.5 s 无帧触发指数退避重连（`min(5s, 500ms × 2^n)`）
- [x] 调试面板不进入 Release 包 —— `Debug/RemoteToolDebugPanel.swift` 整体在 `#if DEBUG` 内，
      验收时用 `Release` 构建跑一次 `nm -a RemoteTooliOS.app/RemoteTooliOS | grep -c RemoteToolDebugPanel`
      应得 `0`

> 最后一项是真的要在 Release 构建产物上跑一次命令确认的，不是看源码推断。

---

## 七、第一次真机联调建议顺序

1. 电脑端启动服务端（默认 `http://<内网 IP>:5104`），确认局域网可达。
2. iOS 上「添加设备」：只填 `192.168.x.x:5104`（Debug 会自动补 `http://`），
   保存前客户端会先打 `/api/device/identity` 校验指纹。
3. 登录 → 「系统」页看 CPU / 内存 / 网络曲线是否与服务端一致。
4. 「终端」页切 `powershell` / `cmd` / `shell`，跑一条 `echo` 确认按行输入生效。
5. 「远程」页连远控：先确认出画，再看调试面板的采集方式、解码路径、键鼠 ack。
6. 断流恢复：把电脑锁屏 10 秒再解锁，确认自动重连而不是卡死。
7. 切到「省流」档位，确认重连后码率与分辨率变化符合预期。

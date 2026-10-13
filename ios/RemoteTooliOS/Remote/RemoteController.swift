import Foundation
import UIKit

/// 远程桌面会话协调器。对应 Android `RemoteActivity` 的全部状态机：
/// 连接 / 回退 / 看门狗 / 指数退避重连 / 相对位移发送 / 修饰键保持 / 实时指标。
///
/// 之所以拆出来而不是塞进 SwiftUI 视图：Android 的这套状态机挂在 Activity 上，
/// 生命周期与视图绑定；SwiftUI 视图会被反复重建，状态必须放独立对象里才不会丢连接。
@MainActor
final class RemoteController: ObservableObject {
    // MARK: - 对外状态

    @Published private(set) var statusText = "连接中…"
    @Published private(set) var metricsText = ""
    @Published private(set) var qualityIndex = RemoteQuality.load()
    @Published private(set) var isTrackpad = false
    /// H.264 路径已经出画。
    @Published private(set) var videoActive = false
    /// 已回退到 MJPEG 兼容模式。
    @Published private(set) var fallbackActive = false
    @Published private(set) var captureMethod: String?
    @Published private(set) var videoWidth = 1920
    @Published private(set) var videoHeight = 1080
    @Published private(set) var heldModifiers: Set<Int> = []
    @Published private(set) var hasVideoFrame = false
    /// 工具栏是否可见。Android 用 3.2 秒自动隐藏 + 点击画面立即隐藏，这里保持一致。
    @Published private(set) var toolsVisible = true
    /// 画面两侧留白够宽时，工具栏改为左右纵向排布（对应 Android `sideTools`）。
    @Published private(set) var sideTools = false
    @Published var transientMessage: String?

    private var hideToolsTask: Task<Void, Never>?
    private let toolsAutoHideDelay: TimeInterval = 3.2

    let endpoint: String
    private let cookie: String

    // MARK: - 会话状态

    private weak var stage: VideoStageView?
    private weak var touch: TouchSurfaceView?

    private var running = false
    private var sessionEpoch = 0
    private var h264: H264StreamClient?
    private var mjpeg: MjpegStreamClient?
    private var inputChannel: InputChannel?
    private let motionQueue = RelativeMotionQueue()

    private var recoveryAttempts = 0
    private var pendingRecovery: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var metricsTimer: Task<Void, Never>?
    private var inputChain: Task<Void, Never>?

    private var jpegBytes: Int64 = 0
    private var jpegFrames: Int64 = 0
    private var lastJpegFrameAt: TimeInterval = 0
    private var statsAt: TimeInterval = 0
    private var statsBytes: Int64 = 0
    private var statsFrames: Int64 = 0

    private let streamTimeout: TimeInterval = 10
    private let watchdogInterval: TimeInterval = 2.5
    private let frameHealthWindow: TimeInterval = 6.5

    init(endpoint: String, cookie: String) {
        self.endpoint = endpoint
        self.cookie = cookie
    }

    // 这里刻意不实现 `deinit` 里取消 Task：`deinit` 不在 MainActor 上，
    // 读写 `pendingRecovery` / `watchdog` / `metricsTimer` 这些主线程隔离状态在 Swift 6 下是编译错误。
    // 清理统一走 `stop()`（由 `RemoteControlScreen` 的 `onDisappear` 调用）；即使漏调，
    // 所有后台 Task 都用 `[weak self]` 捕获，发现 self 已释放后会自行退出。

    // MARK: - 视图挂载

    func attach(stage: VideoStageView, touch: TouchSurfaceView) {
        self.stage = stage
        self.touch = touch
        touch.isTrackpad = isTrackpad
        stage.setMediaSize(width: videoWidth, height: videoHeight)
    }

    // MARK: - 生命周期（对应 onResume / onPause / onDestroy）

    func start() {
        guard !running else { return }
        // 远程桌面必须常亮，否则操作到一半息屏。Android 侧靠沉浸式全屏规避，这里显式禁用自动锁屏。
        UIApplication.shared.isIdleTimerDisabled = true

        running = true
        motionQueue.reset()
        let epoch = nextEpoch()
        recoveryAttempts = 0
        fallbackActive = false
        videoActive = false
        hasVideoFrame = false
        lastJpegFrameAt = 0
        jpegBytes = 0
        jpegFrames = 0
        statsBytes = 0
        statsFrames = 0
        statsAt = Date().timeIntervalSince1970

        RemoteDiagnostics.shared.reset()
        RemoteDiagnostics.shared.publish { snapshot in
            snapshot.endpoint = self.endpoint
            snapshot.quality = RemoteQuality.name(self.qualityIndex)
            snapshot.mode = DebugOverrides.forceMjpeg ? "MJPEG（调试强制）" : "H.264"
            snapshot.videoSize = "\(self.videoWidth)×\(self.videoHeight)"
        }

        stage?.setVideoMode(true)
        statusText = "连接中…"
        startMetrics()
        // 调试面板勾了「强制 MJPEG」就直接走兼容路径，省掉一次注定失败的解码尝试。
        if DebugOverrides.forceMjpeg {
            fallback(epoch: epoch)
            startInputChannel(epoch: epoch)
            startWatchdog()
            showTools()
            return
        }
        startInputChannel(epoch: epoch)
        startH264(epoch: epoch)

        // 10 秒还没出画 → 直接回退 MJPEG，不等看门狗一轮轮重试。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(streamTimeout * 1_000_000_000))
            guard let self, self.running, epoch == self.sessionEpoch, !self.videoActive else { return }
            self.fallback(epoch: epoch)
        }
        startWatchdog()
        showTools()
    }

    func stop() {
        pendingRecovery?.cancel()
        pendingRecovery = nil
        watchdog?.cancel()
        watchdog = nil
        metricsTimer?.cancel()
        metricsTimer = nil
        hideToolsTask?.cancel()
        hideToolsTask = nil

        running = false
        _ = nextEpoch()

        h264?.close()
        h264 = nil
        mjpeg?.close()
        mjpeg = nil

        let keys = heldModifiers
        heldModifiers = []
        let closing = inputChannel
        inputChannel = nil

        // 断开前把手上的修饰键补一个抬起，避免远程电脑的 Ctrl / Alt 卡住。
        if !keys.isEmpty || closing != nil {
            let payloads = keys.map { jsonObject(("type", "keyboard"), ("vkCode", $0), ("isKeyDown", false)) }
            enqueueInput { [weak self] in
                guard let self else { return }
                for payload in payloads {
                    try? await self.postRaw("/api/input/keyboard", body: payload)
                }
                closing?.close()
            }
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func reconnect() {
        recoveryAttempts = 0
        stop()
        start()
    }

    // MARK: - 会话纪元

    @discardableResult
    private func nextEpoch() -> Int {
        sessionEpoch += 1
        return sessionEpoch
    }

    // MARK: - H.264

    private func startH264(epoch: Int) {
        guard running, epoch == sessionEpoch, h264 == nil, let stage else { return }
        stage.setVideoMode(true)

        // 调试面板可以整体改写 /api/stream 的查询串，用来验证服务端白名单边界。
        let query = DebugOverrides.streamQuery ?? RemoteQuality.query(qualityIndex)
        let url = endpoint + "/api/stream?format=h264&" + query
        let client = H264StreamClient(url: url, cookie: cookie, displayLayer: stage.displayLayer)

        client.onSizeChange = { [weak self] width, height in
            guard let self, self.running, epoch == self.sessionEpoch else { return }
            self.videoWidth = width
            self.videoHeight = height
            self.stage?.setMediaSize(width: width, height: height)
            self.hasVideoFrame = true
        }
        client.onFirstFrame = { [weak self] hardware in
            guard let self, self.running, epoch == self.sessionEpoch else { return }
            self.videoActive = true
            self.hasVideoFrame = true
            self.stage?.setVideoMode(true)
            self.statusText = hardware ? "H.264 硬件解码" : "H.264 软件解码"
            RemoteDiagnostics.shared.publish { $0.hardwareDecoding = hardware }
            // 连续 3 秒有帧就把退避计数清零。
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.running, epoch == self.sessionEpoch else { return }
                if let client = self.h264,
                   Date().timeIntervalSince1970 - client.lastFrameAt < 2.5 {
                    self.recoveryAttempts = 0
                }
            }
        }
        client.onCaptureMethod = { [weak self] method in
            self?.captureMethod = method
            RemoteDiagnostics.shared.publish { $0.captureMethod = method }
        }
        client.onError = { [weak self] error in
            guard let self, self.running, epoch == self.sessionEpoch else { return }
            RemoteDiagnostics.shared.noteError("H.264：\(error.localizedDescription)")
            if self.recoveryAttempts < 2 {
                self.recoverVideo(epoch: epoch, reason: error.localizedDescription)
            } else {
                self.fallback(epoch: epoch)
            }
        }

        client.start()
        h264 = client
    }

    // MARK: - MJPEG 回退

    private func fallback(epoch: Int) {
        guard running, epoch == sessionEpoch, !fallbackActive else { return }
        fallbackActive = true
        videoActive = false
        hasVideoFrame = false

        h264?.close()
        h264 = nil

        stage?.setVideoMode(false)
        statusText = "MJPEG 兼容模式"
        RemoteDiagnostics.shared.publish { $0.mode = "MJPEG" }

        let client = MjpegStreamClient(url: endpoint + "/api/stream/legacy", cookie: cookie)
        // 注意 `[weak client]`：回调存在 client 自己身上，强引用 client 会形成循环引用，
        // 导致回退过一次的画面流永远不释放。
        client.onFrame = { [weak self, weak client] image, width, height in
            guard let self, self.running, epoch == self.sessionEpoch else { return }
            self.jpegFrames += 1
            self.jpegBytes = client?.receivedBytes ?? self.jpegBytes
            self.lastJpegFrameAt = Date().timeIntervalSince1970
            self.videoWidth = width
            self.videoHeight = height
            if self.jpegFrames == 1 { self.hasVideoFrame = true }
            self.stage?.showImage(image, size: CGSize(width: width, height: height))
        }
        client.onError = { [weak self] error in
            guard let self, self.running, epoch == self.sessionEpoch else { return }
            RemoteDiagnostics.shared.noteError("MJPEG：\(error.localizedDescription)")
            self.recoverVideo(epoch: epoch, reason: error.localizedDescription)
        }
        client.start()
        mjpeg = client
    }

    // MARK: - 看门狗与恢复

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(2_500_000_000))
                guard let self, self.running else { return }
                let last = self.videoActive ? (self.h264?.lastFrameAt ?? 0) : self.lastJpegFrameAt
                guard last > 0 else { continue }
                if Date().timeIntervalSince1970 - last > self.frameHealthWindow {
                    self.recoverVideo(epoch: self.sessionEpoch, reason: "frame timeout")
                }
            }
        }
    }

    /// 指数退避重连：`min(5s, 500ms * 2^attempts)`，与 Android 完全一致。
    private func recoverVideo(epoch: Int, reason: String) {
        guard running, epoch == sessionEpoch, pendingRecovery == nil else { return }
        statusText = "画面暂时中断，正在恢复…"
        let exponent = min(recoveryAttempts, 4)
        recoveryAttempts += 1
        let delay = min(5.0, 0.5 * pow(2.0, Double(exponent)))

        pendingRecovery = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.pendingRecovery = nil
            guard self.running, epoch == self.sessionEpoch else { return }
            self.stop()
            self.start()
        }
    }

    // MARK: - 实时指标

    private func startMetrics() {
        metricsTimer?.cancel()
        metricsTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.updateMetrics()
            }
        }
    }

    private func updateMetrics() {
        let bytes = h264?.receivedBytes ?? jpegBytes
        let frames = h264?.renderedFrames ?? jpegFrames
        let now = Date().timeIntervalSince1970
        let seconds = now - statsAt

        if seconds > 0, bytes >= statsBytes, frames >= statsFrames {
            let mbps = Double(bytes - statsBytes) * 8 / seconds / 1_000_000
            let fps = Double(frames - statsFrames) / seconds
            let mode = fallbackActive ? "MJPEG" : "H.264"
            metricsText = String(format: "%@ · %@ · %d×%d  %.2f Mbps  %.0f fps",
                                 RemoteQuality.name(qualityIndex), mode,
                                 videoWidth, videoHeight, mbps, fps)
        }
        statsAt = now
        statsBytes = bytes
        statsFrames = frames

        RemoteDiagnostics.shared.publish { snapshot in
            snapshot.status = self.statusText
            snapshot.metrics = self.metricsText
            snapshot.receivedBytes = bytes
            snapshot.renderedFrames = frames
            snapshot.lastFrameAt = self.videoActive ? (self.h264?.lastFrameAt ?? 0) : self.lastJpegFrameAt
            snapshot.videoSize = "\(self.videoWidth)×\(self.videoHeight)"
            snapshot.mode = self.fallbackActive ? "MJPEG" : "H.264"
        }
    }

    // MARK: - 画质

    func selectQuality(_ index: Int) {
        let clamped = RemoteQuality.clamp(index)
        guard clamped != qualityIndex else { return }
        qualityIndex = clamped
        RemoteQuality.save(clamped)
        stage?.resetZoom()
        reconnect()
    }

    // MARK: - 工具模式

    func toggleTrackpad() {
        isTrackpad.toggle()
        touch?.isTrackpad = isTrackpad
    }

    /// 对应工具栏「适应」按钮：把缩放与平移复位。
    func resetZoom() {
        stage?.resetZoom()
    }

    // MARK: - 工具栏显隐（对应 RemoteActivity.showTools / hideTools / toggleTools）

    /// 显示工具栏并重新计时 3.2 秒后自动隐藏。所有工具栏按钮点击都会先调用它。
    func showTools() {
        hideToolsTask?.cancel()
        toolsVisible = true
        hideToolsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toolsVisible = false
        }
    }

    /// 手指落在画面上：立即隐藏工具栏（对应 `ui.removeCallbacks(hideTools); hideTools.run()`）。
    func beginInteraction() {
        hideToolsTask?.cancel()
        toolsVisible = false
    }

    /// 点击画面外空白：可见则隐藏，隐藏则显示。
    func toggleTools() {
        if toolsVisible {
            hideToolsTask?.cancel()
            toolsVisible = false
        } else {
            showTools()
        }
    }

    /// 画面两侧留白足够时切到左右纵向工具栏。阈值与 Android 一致：留白 ≥ 56 pt，栏宽 ≤ 116 pt。
    func updateToolLayout(availableWidth: CGFloat, availableHeight: CGFloat) {
        guard videoWidth > 0, videoHeight > 0, availableWidth > 0, availableHeight > 0 else { return }
        let fit = min(availableWidth / CGFloat(videoWidth), availableHeight / CGFloat(videoHeight))
        let gap = (availableWidth - CGFloat(videoWidth) * fit) / 2
        let shouldUseSides = availableWidth > availableHeight && gap >= 56
        if shouldUseSides != sideTools { sideTools = shouldUseSides }
    }

    /// 供 UI 计算纵向工具栏宽度。
    func railWidth(availableWidth: CGFloat, availableHeight: CGFloat) -> CGFloat {
        guard videoWidth > 0, videoHeight > 0, availableWidth > 0, availableHeight > 0 else { return 0 }
        let fit = min(availableWidth / CGFloat(videoWidth), availableHeight / CGFloat(videoHeight))
        let gap = (availableWidth - CGFloat(videoWidth) * fit) / 2
        return min(gap, 116)
    }

    // MARK: - 输入通道

    private func startInputChannel(epoch: Int) {
        let channel = InputChannel(base: endpoint, cookie: cookie)
        Task { [weak self] in
            do {
                try await channel.open()
                guard let self, self.running, epoch == self.sessionEpoch else {
                    channel.close()
                    return
                }
                self.inputChannel = channel
                RemoteDiagnostics.shared.publish { $0.ackSupported = channel.supportsAck ? "支持" : "不支持（回退 HTTP）" }
            } catch {
                RemoteDiagnostics.shared.noteError("键鼠通道：\(error.localizedDescription)")
                channel.close()
            }
        }
    }

    /// 串行化输入发送。Android 用一个单线程 executor 保证按下 / 移动 / 抬起不会乱序，
    /// 这里用一条 Task 链达到同样效果。
    private func enqueueInput(_ operation: @escaping @MainActor () async -> Void) {
        let previous = inputChain
        inputChain = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func transmit(_ payload: JSONDict, epoch: Int) {
        let type = payload.str("type")
        let isRelease = type == "mouse-up" || (type == "keyboard" && !payload.bool("isKeyDown"))
        enqueueInput { [weak self] in
            guard let self else { return }
            if epoch != self.sessionEpoch, !isRelease { return }
            guard let text = JSONCoding.string(payload) else { return }

            // 按下类事件必须确认送达（点击 / 文本输入），移动类事件走 WebSocket 追求低延迟。
            let needsConfirmation = ["click", "pointer-click", "text"].contains(type)
            if !needsConfirmation, let channel = self.inputChannel {
                do {
                    if try await channel.send(text) { return }
                } catch {
                    channel.close()
                    if self.inputChannel === channel { self.inputChannel = nil }
                }
            }
            do {
                try await self.postRaw("/api/input/" + type, body: payload)
            } catch {
                self.transientMessage = "输入失败，请重连：\(connectionFailureMessage(error))"
            }
        }
    }

    /// 相对位移：一条在途 + ack 确认。
    /// 服务端不支持 ack 时退回 HTTP 已确认通道，保证「最多一条移动在途」。
    private func transmitRelative(dx: Int, dy: Int, epoch: Int) async {
        guard epoch == sessionEpoch, running else { return }
        let payload = jsonObject(("type", "mouse-relative"), ("x", 0), ("y", 0), ("dx", dx), ("dy", dy))

        if let channel = inputChannel, channel.supportsAck {
            var withAck = payload
            withAck["ack"] = true
            let baseline = channel.latestAckCount
            do {
                if try await channel.send(withAck) {
                    try await channel.waitForAck(above: baseline, timeout: 2)
                    return
                }
            } catch {
                channel.close()
                if inputChannel === channel { inputChannel = nil }
                return
            }
        }
        try? await postRaw("/api/input/mouse-relative", body: payload)
    }

    // MARK: - 触摸回调（由 TouchSurfaceDelegate 转发）

    func handleRelativeMove(dx: Double, dy: Double) {
        guard running else { return }
        let epoch = sessionEpoch
        guard motionQueue.offer(dx, dy) else { return }
        enqueueInput { [weak self] in
            guard let self else { return }
            while self.running, epoch == self.sessionEpoch, let move = self.motionQueue.take() {
                await self.transmitRelative(dx: move.dx, dy: move.dy, epoch: epoch)
            }
        }
    }

    func sendCursorMove(to point: CGPoint) {
        transmit(jsonObject(("type", "mouse-move"), ("x", Double(point.x)), ("y", Double(point.y))),
                 epoch: sessionEpoch)
    }

    func sendPress(button: Int) {
        guard let cursor = touch?.currentCursor else { return }
        transmit(jsonObject(("type", "mouse-down"), ("x", Double(cursor.x)), ("y", Double(cursor.y)), ("button", button)),
                 epoch: sessionEpoch)
    }

    func sendRelease(button: Int) {
        guard let cursor = touch?.currentCursor else { return }
        transmit(jsonObject(("type", "mouse-up"), ("x", Double(cursor.x)), ("y", Double(cursor.y)), ("button", button)),
                 epoch: sessionEpoch)
    }

    func sendClick(button: Int) {
        let cursor = touch?.currentCursor ?? CGPoint(x: 0.5, y: 0.5)
        let type: String
        if isTrackpad {
            type = "pointer-click"
        } else {
            type = button == 2 ? "right-click" : "click"
        }
        transmit(jsonObject(("type", type), ("x", Double(cursor.x)), ("y", Double(cursor.y)), ("button", button)),
                 epoch: sessionEpoch)
    }

    func sendWheel(delta: Int) {
        let cursor = touch?.currentCursor ?? CGPoint(x: 0.5, y: 0.5)
        let type = isTrackpad ? "pointer-wheel" : "mouse-wheel"
        transmit(jsonObject(("type", type), ("x", Double(cursor.x)), ("y", Double(cursor.y)),
                            ("delta", delta), ("dy", delta)),
                 epoch: sessionEpoch)
    }

    /// 双指上下滑：线格式与 Android 一致（x/y 为 0，只带 dy）。
    func sendTwoFingerScroll(delta: Int) {
        transmit(jsonObject(("type", "pointer-wheel"), ("x", 0), ("y", 0), ("dy", delta)),
                 epoch: sessionEpoch)
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        transmit(jsonObject(("type", "text"), ("text", text)), epoch: sessionEpoch)
    }

    func sendKey(_ code: Int, isDown: Bool) {
        transmit(jsonObject(("type", "keyboard"), ("vkCode", code), ("isKeyDown", isDown)),
                 epoch: sessionEpoch)
    }

    /// 点按型按键（Esc / Enter / Tab / 退格）：按下后 65 ms 抬起，与 Android 一致。
    func tapKey(_ code: Int) {
        sendKey(code, isDown: true)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 65_000_000)
            self?.sendKey(code, isDown: false)
        }
    }

    func toggleModifier(_ code: Int) {
        let down = !heldModifiers.contains(code)
        if down { heldModifiers.insert(code) } else { heldModifiers.remove(code) }
        sendKey(code, isDown: down)
    }

    var isCtrlHeld: Bool { heldModifiers.contains(17) }
    var isAltHeld: Bool { heldModifiers.contains(18) }

    // MARK: - HTTP 兜底通道

    private func postRaw(_ path: String, body: JSONDict) async throws {
        guard let url = URL(string: endpoint + path), let data = JSONCoding.data(body) else {
            throw NSError(domain: "RemoteTool.Input", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "输入地址无效"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 输入是交互操作，超时必须短：宁可失败让用户重按，也不要卡住输入链。
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "RemoteTool.Input", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "输入 HTTP \(code)"])
        }
    }
}

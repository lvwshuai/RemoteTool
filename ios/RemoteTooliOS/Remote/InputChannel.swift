import Foundation

/// 键鼠输入通道：`/ws/input`。
///
/// 对应 Android `RemoteActivity.InputSocket`，但用系统 WebSocket 而不是手写握手 —— 差异说明：
///
/// 1. **Cookie 必须显式放在请求头上。** `URLSessionWebSocketTask` 不会自动附加
///    `HTTPCookieStorage` 里的 cookie（长期存在的平台行为），所以这里直接从请求头带 `access_token`。
///    服务端同时也接受 `?access_token=` 查询串，但我们**故意不用**：
///    查询串会写进反向代理日志与设备日志，等于把长期有效的 token 泄露出去。
///
/// 2. **ack 能力探测方式。** Android 手写握手所以能读 `X-Chuckie-Input-Ack: 1` 响应头；
///    `URLSessionWebSocketTask` 不暴露握手响应头，因此改成主动探测：
///    发一条 `mouse-relative dx=0 dy=0 ack=true`，服务端
///    （`InputWebSocketHandler.DispatchAsync` 对 dx/dy 同时为 0 的 `mouse-relative` 直接 return，
///    不会合成鼠标动作）只会回一条 `{"type":"input-ack"}`。
///    收到即认为支持 ack；超时则退回 HTTP 已确认通道。
final class InputChannel {
    enum ChannelError: LocalizedError {
        case notOpen
        case ackTimeout
        case handshakeFailed(Int)

        var errorDescription: String? {
            switch self {
            case .notOpen: return "输入通道未建立"
            case .ackTimeout: return "输入通道没有响应确认"
            case .handshakeFailed(let code): return "输入通道握手失败 HTTP \(code)"
            }
        }
    }

    private let base: String
    private let cookie: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    private let lock = NSLock()
    private var ackCount = 0
    private var closed = false

    private(set) var supportsAck = false
    private(set) var isOpen = false
    /// 建立通道耗时（毫秒），与 Android 日志中的同一指标对应。
    private(set) var readyMilliseconds: Int = 0

    init(base: String, cookie: String) {
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.base = trimmed
        self.cookie = cookie
    }

    /// 建立连接并探测 ack 能力。抛错说明通道不可用，调用方应回退到 HTTP 通道。
    func open() async throws {
        guard let url = URL(string: webSocketBase(base) + "/ws/input") else { throw ChannelError.notOpen }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !cookie.isEmpty {
            // 关键：显式请求头，不能依赖 cookie 存储。
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieAcceptPolicy = .always
        let created = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        session = created

        let webSocket = created.webSocketTask(with: request)
        task = webSocket
        webSocket.resume()

        lock.lock()
        closed = false
        lock.unlock()

        startReceiveLoop(webSocket)

        let started = Date()
        // 探测 ack：这条命令服务端不会真正移动鼠标，只是回一个 input-ack。
        let baseline = currentAckCount()
        _ = try? await send(jsonObject(("type", "mouse-relative"), ("dx", 0), ("dy", 0), ("ack", true)))
        do {
            try await waitForAck(above: baseline, timeout: 2.5)
            supportsAck = true
        } catch {
            supportsAck = false
        }
        readyMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        isOpen = true
    }

    func send(_ payload: [String: Any]) async throws -> Bool {
        guard let data = JSONCoding.string(payload) else { return false }
        return try await send(data)
    }

    func send(_ text: String) async throws -> Bool {
        lock.lock()
        let isClosed = closed
        let current = task
        lock.unlock()
        guard !isClosed, let current else { return false }
        try await current.send(.string(text))
        return true
    }

    /// 等待一次 `input-ack`。
    ///
    /// 用轮询而不是 continuation：这里的设计是「同一时刻只有一条相对位移在途」
    /// （见 `RelativeMotionQueue`），所以只需要知道「有没有新的 ack 到来」，
    /// 轮询间隔 1.5 ms 带来的额外延迟远小于一次网络往返，同时避免了 continuation 泄漏与取消清理的复杂度。
    func waitForAck(above baseline: Int, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if currentAckCount() > baseline { return }
            if Date() >= deadline { throw ChannelError.ackTimeout }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_500_000)
        }
    }

    var latestAckCount: Int { currentAckCount() }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let current = task
        task = nil
        lock.unlock()

        receiveTask?.cancel()
        receiveTask = nil
        current?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        isOpen = false
    }

    // MARK: - 接收

    private func startReceiveLoop(_ webSocket: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await webSocket.receive()
                    guard let self else { return }
                    switch message {
                    case .string(let text):
                        self.handle(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self else { return }
                    // 握手被拒时能拿到 HTTP 状态码，便于区分「token 失效」与「网络中断」。
                    if let response = webSocket.response as? HTTPURLResponse, response.statusCode != 101 {
                        _ = ChannelError.handshakeFailed(response.statusCode)
                    }
                    self.lock.lock()
                    self.closed = true
                    self.isOpen = false
                    self.lock.unlock()
                    return
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let object = JSONCoding.parse(text) as? JSONDict else { return }
        guard object.str("type") == "input-ack" else { return }
        lock.lock()
        ackCount += 1
        lock.unlock()
    }

    private func currentAckCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return ackCount
    }
}

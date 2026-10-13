import Foundation

/// 运行时调试开关。
///
/// 为什么放在 `Core/` 而不是只放在 `Debug/`：`NativeApi` / `RemoteController` 这些
/// **发布路径**也要查询开关，如果整个文件被 `#if DEBUG` 包住，Release 构建就找不到符号。
/// 因此这里保留类本身，把每个访问器分别按编译条件实现 —— Release 下恒为「关闭」，
/// 编译器会把调用点优化成常量，二进制里不会留下调试能力。
enum DebugOverrides {
    static let baseAddressKey = "debug.baseAddress"
    static let forceMjpegKey = "debug.forceMjpeg"
    static let streamQueryKey = "debug.streamQuery"
    static let allowCleartextKey = "debug.allowCleartext"
    static let networkLogKey = "debug.networkLog"

    #if DEBUG
    private static func flag(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    private static func text(_ key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 基址覆盖（LAN / IPv6 / 域名 / VPN 地址都可）。
    static var baseAddress: String? {
        guard var value = text(baseAddressKey) else { return nil }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return value
    }

    static var forceMjpeg: Bool { flag(forceMjpegKey, false) }
    static var streamQuery: String? { text(streamQueryKey) }
    static var allowCleartext: Bool { flag(allowCleartextKey, true) }
    static var networkLogEnabled: Bool { flag(networkLogKey, false) }
    #else
    static var baseAddress: String? { nil }
    static var forceMjpeg: Bool { false }
    static var streamQuery: String? { nil }
    static var allowCleartext: Bool { false }
    static var networkLogEnabled: Bool { false }
    #endif

    /// 把请求的 origin 改写到调试基址，路径与查询串保持不变。
    ///
    /// 语义很直白：调试版允许「让 App 以为某设备在另一个地址上」。
    /// 代价是端点身份校验也会跟着走到覆盖地址（这正是调试想要的：验证新地址是不是同一台机器）。
    static func apply(base: String) -> String {
        #if DEBUG
        guard let override = baseAddress,
              let original = URL(string: base),
              let replacement = URL(string: override) else { return base }
        var components = URLComponents(url: original, resolvingAgainstBaseURL: false)
        components?.scheme = replacement.scheme
        components?.host = replacement.host
        components?.port = replacement.port
        return components?.string ?? base
        #else
        return base
        #endif
    }
}

/// 远控会话的实时指标快照，供调试面板读取。
///
/// 指标本体住在 `RemoteController` 里（它才是唯一知道当前帧率与 capture method 的地方），
/// 这里只做一个线程安全的观测点，避免为了调试面板把整个远控状态机抬成单例。
final class RemoteDiagnostics {
    static let shared = RemoteDiagnostics()

    struct Snapshot {
        var endpoint = ""
        var quality = ""
        var status = ""
        var metrics = ""
        var mode = ""
        var captureMethod: String?
        var receivedBytes: Int64 = 0
        var renderedFrames: Int64 = 0
        var lastFrameAt: TimeInterval = 0
        var hardwareDecoding = false
        var videoSize = "—"
        var ackSupported: String = "未知"
        var lastError = ""
    }

    private let lock = NSLock()
    private var stored = Snapshot()
    private var lastErrorText = ""

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func publish(_ mutate: (inout Snapshot) -> Void) {
        lock.lock()
        mutate(&stored)
        if !lastErrorText.isEmpty { stored.lastError = lastErrorText }
        lock.unlock()
    }

    func noteError(_ text: String) {
        lock.lock()
        lastErrorText = "\(remoteClock())  \(text)"
        stored.lastError = lastErrorText
        lock.unlock()
    }

    func reset() {
        lock.lock()
        lastErrorText = ""
        stored = Snapshot()
        lock.unlock()
    }

    private func remoteClock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

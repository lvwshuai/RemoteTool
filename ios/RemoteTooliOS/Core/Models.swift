import Foundation

// MARK: - 设备与通道

struct Device: Identifiable, Equatable, Hashable {
    let id: String          // 服务端 /api/device/identity 返回的 64 位十六进制指纹
    var name: String
    var endpoints: [String]
}

struct Endpoint: Equatable, Hashable {
    let url: String
    let ms: Int
}

struct ChannelCheck: Identifiable, Equatable {
    enum State: Equatable {
        case checking
        case reachable(ms: Int)
        case failed(reason: String)
    }

    var url: String
    var state: State

    var id: String { url }
    var isReachable: Bool { if case .reachable = state { return true }; return false }
    var ms: Int? { if case .reachable(let value) = state { return value }; return nil }
    var error: String? { if case .failed(let reason) = state { return reason }; return nil }
}

/// 已连上的会话：设备 + 可用通道（当前通道排最后，便于「切换通道」把它显示在末尾）+ API。
struct Session: Identifiable {
    let device: Device
    let channels: [Endpoint]
    let api: NativeApi

    var id: String { device.id }
}

// MARK: - 凭据

/// 保存的登录凭据。`password` 只在本地加密存放，任何日志/描述都不会泄露它。
struct DeviceLogin {
    var username: String
    var password: String
    var token: String

    func withToken(_ value: String) -> DeviceLogin {
        DeviceLogin(username: username, password: password, token: value)
    }
}

extension DeviceLogin: CustomStringConvertible {
    var description: String { "DeviceLogin(redacted)" }
}

/// 每个设备一个可变 token 槽位（对应 Android 的 `DeviceAuthSession`）。
final class DeviceAuthSession {
    private let lock = NSLock()
    private var stored: String?

    init(token: String? = nil) { stored = token }

    var token: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

// MARK: - 错误

/// 服务端返回 401。对应 Android 的 `LoginRequired`。
struct LoginRequired: LocalizedError {
    var errorDescription: String? { "登录已过期，请重新登录" }
}

/// 非 2xx 或业务失败。保留 status / code / delivery 供上层区分「写入被拒」与「结果未知」。
struct ApiRequestFailure: LocalizedError {
    let message: String
    let status: Int
    let code: String
    let delivery: String

    init(_ message: String, status: Int, code: String = "", delivery: String = "") {
        self.message = message
        self.status = status
        self.code = code
        self.delivery = delivery
    }

    var errorDescription: String? { message }

    /// 服务端明确表示没有写入（可以安全重试或提示用户），否则为「结果未知」。
    var writeWasRejected: Bool {
        switch delivery {
        case "rejected": return true
        case "unknown": return false
        default: return (400...499).contains(status)
        }
    }

    /// Codex/Hermes 的历史任务已被回收，需要刷新会话后重发。
    var isStaleRun: Bool {
        if ["run_stale", "run_not_found", "thread_not_loaded"].contains(code) { return true }
        return message.localizedCaseInsensitiveContains("thread not found")
    }
}

/// GET 读取时连接被中断，但服务端状态未知 —— 对应 Android 的 `ReadConnectionFailure`。
struct ReadConnectionFailure: LocalizedError {
    let underlying: Error
    var errorDescription: String? { "读取时连接暂时中断，请重新连接" }
}

/// 所有候选地址都连不上。
struct DeviceAddressFailure: LocalizedError {
    let attempts: [(url: String, error: Error)]
    var errorDescription: String? {
        "所有地址均无法连接（\(attempts.count) 个）：" +
            attempts.map { "\($0.url)：\((($0.error as? LocalizedError)?.errorDescription) ?? "\($0.error)")" }
                .joined(separator: "；")
    }
}

/// 读请求是否值得换一条新连接重试（最多一次，且仅 GET/HEAD、非探测、非 401）。
func mayRetryRead(method: String, probing: Bool, attempt: Int, error: Error, noRetry: Bool = false) -> Bool {
    guard method == "GET" || method == "HEAD" else { return false }
    guard !probing, !noRetry, attempt == 0 else { return false }
    if error is LoginRequired { return false }
    if let failure = error as? ApiRequestFailure {
        return [502, 503, 504].contains(failure.status)
    }
    return error is URLError || error is ReadConnectionFailure
}

/// 把底层错误翻译成用户能看懂的一句话，等价 Android `connectionFailureMessage`。
func connectionFailureMessage(_ error: Error) -> String {
    switch error {
    case let failure as ApiRequestFailure:
        return failure.message
    case let failure as ReadConnectionFailure:
        return failure.errorDescription ?? "读取时连接暂时中断，请重新连接"
    case let failure as DeviceAddressFailure:
        return failure.errorDescription ?? "所有地址均无法连接"
    case let failure as LoginRequired:
        return failure.errorDescription ?? "登录已过期，请重新登录"
    default:
        break
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "无法解析设备地址，请检查网络后重新连接"
        case .timedOut:
            return "连接超时，请检查当前设备通道"
        case .networkConnectionLost, .notConnectedToInternet:
            return "网络连接已中断，请重新连接"
        case .cannotConnectToHost, .connectionRefused:
            return "无法连接，服务或端口不可达"
        case .appTransportSecurityRequiresSecureConnection:
            return "明文连接被系统拦截。请在调试版中允许明文，或给服务端配置 HTTPS"
        default:
            return urlError.localizedDescription
        }
    }
    return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

/// 通道探测失败的归类，等价 Android `NativeModel.channelError`。
func channelErrorText(_ error: Error) -> String {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "域名无法解析，请检查 DNS / VPN 设置"
        case .timedOut:
            return "连接超时，请检查网络或防火墙"
        case .cannotConnectToHost, .connectionRefused:
            return "无法连接，服务或端口不可达"
        default:
            break
        }
    }
    let message = connectionFailureMessage(error)
    return message.isEmpty ? "检测失败" : message
}

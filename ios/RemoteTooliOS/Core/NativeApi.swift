import Foundation

/// 阻止 HTTP 重定向。等价 Android OkHttp 的 `followRedirects(false)` / `followSslRedirects(false)`：
/// 服务端接口不应重定向，跟随重定向会把带 token 的请求发到未知主机。
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirectDelegate()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// 服务端 API 客户端，逐条对齐 Android `nativeui/NativeData.kt` 的 `NativeApi`。
///
/// 与 Android 的两处实现差异（均已在注释里说明原因）：
/// 1. Cookie：OkHttp 由 `CookieManager` 统一管理；iOS 走 `HTTPCookieStorage` 自动收 `Set-Cookie`，
///    同时在请求上显式带 `Cookie` 头（见 `cookie()`）。WebSocket 必须走显式请求头，
///    因为 `URLSessionWebSocketTask` 不会自动附加 cookie 存储里的 cookie（长期存在的系统行为）。
/// 2. 响应解压：不手动设置 `Accept-Encoding`，交给 URLSession 自动协商并透传解压 gzip / br。
final class NativeApi {
    // 服务端通过 `X-RemoteTool-Request-Compression: gzip` 表明支持请求体解压；
    // 只有声明过的 origin 才启用请求压缩，避免打到旧服务端。
    private static let compressionLock = NSLock()
    private static var compressionOrigins = Set<String>()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
    }()

    let base: String
    let probing: Bool
    let noRetry: Bool
    private let onReadSuccess: (() -> Void)?
    private let authentication: DeviceAuthSession?

    init(base: String,
         probing: Bool = false,
         noRetry: Bool = false,
         onReadSuccess: (() -> Void)? = nil,
         authentication: DeviceAuthSession? = nil) {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        // 调试版的基址覆盖：把 origin 换掉，路径与查询串保持不变。
        // Release 下 `apply` 是恒等函数，这一行会被优化掉。
        self.base = DebugOverrides.apply(base: trimmed)
        self.probing = probing
        self.noRetry = noRetry
        self.onReadSuccess = onReadSuccess
        self.authentication = authentication
    }

    /// 复制一份，只改读取策略（对应 Android `withReadPolicy`）。
    func withReadPolicy(noRetry: Bool, onReadSuccess: (() -> Void)? = nil) -> NativeApi {
        NativeApi(base: base, probing: probing, noRetry: noRetry,
                  onReadSuccess: onReadSuccess, authentication: authentication)
    }

    // MARK: - Cookie

    /// 优先用内存里的 token；没有则退回 cookie 存储（兼容旧会话）。
    func cookie() -> String {
        if let token = authentication?.token, !token.isEmpty {
            return "access_token=\(token)"
        }
        guard let url = URL(string: base),
              let cookies = HTTPCookieStorage.shared.cookies(for: url) else { return "" }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 登录/恢复 token 后调用：写内存槽位，并把 cookie 放进系统存储（HTTP 与 WebSocket 都会读它）。
    func installToken(_ token: String) {
        authentication?.token = token
        guard let url = URL(string: base) else { return }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "access_token",
            .value: token,
            .path: "/",
            .domain: url.host ?? ""
        ]
        if url.scheme == "https" { properties[.secure] = "TRUE" }
        if let cookie = HTTPCookie(properties: properties) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// 登出：清内存槽位与 cookie 存储。
    func clearToken() {
        authentication?.token = nil
        guard let url = URL(string: base), let host = url.host else { return }
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == "access_token" {
            if cookie.domain.isEmpty || host.contains(cookie.domain) || cookie.domain.contains(host) {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }

    // MARK: - 请求构造

    private var origin: String {
        guard let url = URL(string: base) else { return base }
        let scheme = url.scheme ?? "http"
        let host = url.host ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private func compressionEnabled(for path: String) -> Bool {
        guard path.hasPrefix("/api/") else { return false }
        NativeApi.compressionLock.lock()
        defer { NativeApi.compressionLock.unlock() }
        return NativeApi.compressionOrigins.contains(origin)
    }

    private func makeRequest(_ path: String,
                            method: String,
                            body: JSONDict? = nil,
                            timeout: TimeInterval? = nil,
                            accept: String? = nil) throws -> URLRequest {
        guard let url = URL(string: base + path) else {
            throw ApiRequestFailure("设备地址无效：\(base)", status: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout ?? (probing ? 3.5 : 45)
        if !probing {
            let value = cookie()
            if !value.isEmpty { request.setValue(value, forHTTPHeaderField: "Cookie") }
        }
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        if let body {
            guard var payload = JSONCoding.data(body) else {
                throw ApiRequestFailure("请求体无法序列化", status: 0)
            }
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            if compressionEnabled(for: path), let packed = Gzip.compressIfSmaller(payload) {
                payload = packed
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            }
            request.httpBody = payload
        }
        return request
    }

    // MARK: - 底层发送

    /// 返回原始字节 + 状态码。不解析 JSON，供截图、下载、预览图片等二进制接口使用。
    @discardableResult
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await NativeApi.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ApiRequestFailure("服务返回了非 HTTP 响应", status: 0)
            }
            noteCompressionSupport(http, path: request.url?.path ?? "")
            if http.statusCode == 401 { throw LoginRequired() }
            if request.httpMethod == "GET" || request.httpMethod == "HEAD" {
                onReadSuccess?()
            }
            return (data, http)
        } catch {
            throw translate(error)
        }
    }

    private func noteCompressionSupport(_ response: HTTPURLResponse, path: String) {
        guard path.hasPrefix("/api/") else { return }
        let advertised = response.value(forHTTPHeaderField: "X-RemoteTool-Request-Compression") == "gzip"
        NativeApi.compressionLock.lock()
        if advertised { NativeApi.compressionOrigins.insert(origin) } else { NativeApi.compressionOrigins.remove(origin) }
        NativeApi.compressionLock.unlock()
    }

    private func translate(_ error: Error) -> Error {
        if error is LoginRequired || error is ApiRequestFailure { return error }
        return error
    }

    // MARK: - JSON

    func json(_ path: String, body: JSONDict? = nil, method: String? = nil,
              headers: [String: String] = [:]) async throws -> JSONDict {
        let verb = method ?? (body == nil ? "GET" : "POST")
        var request = try makeRequest(path, method: verb, body: body)
        // 幂等键等业务头。服务端 `Idempotency-Key` 决定「重发是否会重复写入」，必须由调用方给。
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await json(request)
    }

    func json(_ request: URLRequest) async throws -> JSONDict {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await jsonOnce(request)
            } catch {
                let method = request.httpMethod ?? "GET"
                if mayRetryRead(method: method, probing: probing, attempt: attempt, error: error, noRetry: noRetry) {
                    attempt += 1
                    try await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                if (method == "GET" || method == "HEAD"), !probing, !(error is LoginRequired),
                   !(error is ApiRequestFailure) || (error as? ApiRequestFailure).map({ [502, 503, 504].contains($0.status) }) == true {
                    throw ReadConnectionFailure(underlying: error)
                }
                throw error
            }
        }
    }

    private func jsonOnce(_ request: URLRequest) async throws -> JSONDict {
        let (data, http) = try await send(request)
        let parsed = JSONCoding.parse(data)
        let object = parsed as? JSONDict

        if !(200...299).contains(http.statusCode) {
            let message = object?.optStr("message") ?? "请求失败 HTTP \(http.statusCode)"
            throw ApiRequestFailure(message,
                                    status: http.statusCode,
                                    code: object?.str("code") ?? "",
                                    delivery: object?.str("delivery") ?? "")
        }
        guard let object else { throw ApiRequestFailure("服务返回了非 JSON 响应", status: http.statusCode) }
        if object.keys.contains("success"), !object.bool("success") {
            throw ApiRequestFailure(object.str("message", "操作失败"), status: http.statusCode)
        }
        if let dataObject = object.dict("data"), dataObject.int("fail", 0) > 0 {
            throw ApiRequestFailure(object.str("message", "部分项目操作失败"), status: http.statusCode)
        }
        return object
    }

    // MARK: - 认证

    func login(username: String, password: String) async throws -> String {
        var request = try makeRequest("/api/auth/login", method: "POST",
                                      body: jsonObject(("username", username), ("password", password)))
        request.timeoutInterval = 20
        let result = try await json(request)
        let token = result.str("token")
        guard !token.isEmpty else { throw ApiRequestFailure("服务端未返回 token", status: 200) }
        installToken(token)
        return token
    }

    /// 校验当前 token 是否仍然有效（等价 Android 用 `/api/auth/me` 探测）。
    func validateToken(_ token: String) async -> Bool {
        let probeAuth = DeviceAuthSession(token: token)
        let api = NativeApi(base: base, noRetry: true, authentication: probeAuth)
        do {
            _ = try await api.json("/api/auth/me")
            return true
        } catch {
            return false
        }
    }

    // MARK: - 流式文本（SSE / 命令输出）

    /// 逐块回调文本流。用于 Docker/Compose 命令日志与 Agent 的 SSE。
    func stream(_ path: String,
                body: JSONDict? = nil,
                method: String = "POST",
                onChunk: @escaping @Sendable (String) -> Void) async throws {
        let request = try makeRequest(path, method: method, body: body)
        let (bytes, response) = try await NativeApi.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiRequestFailure("服务返回了非 HTTP 响应", status: 0)
        }
        if http.statusCode == 401 { throw LoginRequired() }
        guard (200...299).contains(http.statusCode) else {
            throw ApiRequestFailure("命令失败 HTTP \(http.statusCode)", status: http.statusCode)
        }
        var buffer = [UInt8]()
        buffer.reserveCapacity(4096)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 2048 {
                if let text = String(bytes: buffer, encoding: .utf8) { onChunk(text) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty, let text = String(bytes: buffer, encoding: .utf8) { onChunk(text) }
    }

    // MARK: - SSE（Codex / Hermes 的 run 事件流）

    /// 按 SSE 语义读取事件流：`data:` 行累积，空行触发一次投递。
    ///
    /// 与 `stream(_:)` 的区别：这是给 `/api/{agent}/runs/{id}/events` 用的，
    /// 需要 `Last-Event-ID` 头来续传，且必须按行解析（事件体可以跨多行）。
    /// 服务端明确 SSE 不做压缩，所以这里也不做整体缓冲，逐行消费即可。
    func eventStream(_ path: String, lastEventId: String? = nil) -> AsyncThrowingStream<JSONDict, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    var request = try self.makeRequest(path, method: "GET", timeout: 3600)
                    if let lastEventId, !lastEventId.isEmpty {
                        request.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
                    }
                    let (bytes, response) = try await NativeApi.streamSession.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ApiRequestFailure("服务返回了非 HTTP 响应", status: 0)
                    }
                    if http.statusCode == 401 { throw LoginRequired() }
                    guard (200...299).contains(http.statusCode) else {
                        throw ApiRequestFailure("事件流失败 HTTP \(http.statusCode)", status: http.statusCode)
                    }
                    var buffered = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.isEmpty {
                            if !buffered.isEmpty {
                                if let object = JSONCoding.parse(buffered) as? JSONDict {
                                    continuation.yield(object)
                                }
                                buffered = ""
                            }
                            continue
                        }
                        guard line.hasPrefix("data:") else { continue }
                        var payload = String(line.dropFirst(5))
                        if payload.hasPrefix(" ") { payload.removeFirst() }
                        if !buffered.isEmpty { buffered += "\n" }
                        buffered += payload
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 长连接专用 session：资源超时放宽到 1 小时（`timeoutIntervalForResource` 在默认会话里是 120s，
    /// 会把「长时间没有事件的 run」误判为超时并掐断）。同时保持不跟随重定向。
    private static let streamSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
    }()

    // MARK: - 便捷方法

    func test() async throws -> JSONDict {
        try await json("/api/system/info")
    }

    func screenshot() async throws -> Data {
        let request = try makeRequest("/api/system/screenshot", method: "GET", accept: "image/*")
        let (data, http) = try await send(request)
        guard (200...299).contains(http.statusCode), !data.isEmpty else {
            throw ApiRequestFailure("截图失败 HTTP \(http.statusCode)", status: http.statusCode)
        }
        return data
    }

    /// 下载任意接口的原始响应（文件下载 / 图片预览）。
    func download(_ path: String) async throws -> Data {
        let request = try makeRequest(path, method: "GET")
        let (data, http) = try await send(request)
        guard (200...299).contains(http.statusCode) else {
            throw ApiRequestFailure("下载失败 HTTP \(http.statusCode)", status: http.statusCode)
        }
        return data
    }

    /// 上传二进制内容（文件写入 / 附件上传）。
    func upload(_ path: String, method: String = "POST", contentType: String, body: Data,
                query: String = "") async throws -> JSONDict {
        guard let url = URL(string: base + path + query) else {
            throw ApiRequestFailure("设备地址无效", status: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 300
        let value = cookie()
        if !value.isEmpty { request.setValue(value, forHTTPHeaderField: "Cookie") }
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await json(request)
    }
}

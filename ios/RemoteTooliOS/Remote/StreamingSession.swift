import Foundation

/// 长连接字节流客户端。
///
/// 服务端 `/api/stream?format=h264`（`video/h264`，永不结束）与 `/api/stream/legacy`
/// （`multipart/x-mixed-replace`）都是无限响应。
/// **必须用 `URLSessionDataDelegate` 逐块消费，不能用 `await URLSession.data(for:)`** ——
/// 后者会把整个响应读进内存，远程桌面几秒内就会把 App 撑爆。
///
/// 同时这里承担了「首包校验」：状态码不是 200、或 Content-Type 不符时立刻断开，
/// 让上层能马上判定失败并回退，而不是傻等看门狗超时。
final class StreamingSession: NSObject {
    enum StreamError: LocalizedError {
        case badStatus(Int)
        case badContentType(String?)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "画面 HTTP \(code)"
            case .badContentType(let type): return "画面类型不符：\(type ?? "未知")"
            case .transport(let error): return error.localizedDescription
            }
        }
    }

    private let acceptedContentTypes: [String]
    private let onChunk: (Data) -> Void
    private let onFinish: (Error?) -> Void

    private let queue: OperationQueue
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let lock = NSLock()
    private var finished = false
    private var totalBytes: Int64 = 0
    private var headers: [String: String] = [:]
    private var contentType: String?

    /// - Parameters:
    ///   - acceptedContentTypes: 允许的 Content-Type 子串（大小写不敏感），如 `["video/h264"]`。
    ///   - onChunk: 在后台串行队列上回调，回调里不要做 UI 操作。
    ///   - onFinish: 结束回调（正常结束为 nil，异常为错误）。只回调一次。
    init(acceptedContentTypes: [String],
         onChunk: @escaping (Data) -> Void,
         onFinish: @escaping (Error?) -> Void) {
        self.acceptedContentTypes = acceptedContentTypes.map { $0.lowercased() }
        self.onChunk = onChunk
        self.onFinish = onFinish
        self.queue = OperationQueue()
        self.queue.maxConcurrentOperationCount = 1
        self.queue.qualityOfService = .userInitiated
        super.init()
    }

    var receivedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return totalBytes
    }

    func responseHeader(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return headers[name.lowercased()]
    }

    func start(_ request: URLRequest) {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        // 无限流不能设资源超时，否则会被系统主动掐断。
        configuration.timeoutIntervalForResource = .infinity

        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        session = created
        let dataTask = created.dataTask(with: request)
        task = dataTask
        dataTask.resume()
    }

    func cancel() {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        if !alreadyFinished { onFinish(StreamError.transport(URLError(.cancelled))) }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        session?.finishTasksAndInvalidate()
        session = nil
        onFinish(error)
    }
}

extension StreamingSession: URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(StreamError.badStatus(0))
            return
        }

        var collected: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            collected["\(key)".lowercased()] = "\(value)"
        }
        lock.lock()
        headers = collected
        contentType = http.value(forHTTPHeaderField: "Content-Type")
        lock.unlock()

        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            finish(StreamError.badStatus(http.statusCode))
            return
        }
        if !acceptedContentTypes.isEmpty {
            let type = (contentType ?? "").lowercased()
            guard acceptedContentTypes.contains(where: { type.contains($0) }) else {
                completionHandler(.cancel)
                finish(StreamError.badContentType(contentType))
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        totalBytes += Int64(data.count)
        let closed = finished
        lock.unlock()
        guard !closed else { return }
        onChunk(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as? URLError)?.code == .cancelled {
            // 主动取消不算异常结束。
            lock.lock()
            let alreadyFinished = finished
            lock.unlock()
            if alreadyFinished { return }
        }
        finish(error)
    }
}

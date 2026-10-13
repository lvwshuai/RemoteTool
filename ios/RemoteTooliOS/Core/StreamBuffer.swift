import Foundation

/// 流式文本的线程安全累积器。
///
/// 用途：`NativeApi.stream(_:)` 的回调是 `@Sendable` 的，闭包里不能直接改捕获的 `var`。
/// 用一个带锁的引用类型既能跨隔离域累积，又能保证「取到的永远是完整快照」。
/// 上限与 Android 侧一致（`takeLast(250000)`），避免长任务把内存吃光。
final class StreamBuffer: @unchecked Sendable {
    static let maxLength = 250_000

    private let lock = NSLock()
    private var stored = ""

    /// 追加一块文本并返回累积后的完整内容。
    @discardableResult
    func append(_ chunk: String) -> String {
        lock.lock()
        let merged = stored + chunk
        stored = merged.count > StreamBuffer.maxLength
            ? String(merged.suffix(StreamBuffer.maxLength))
            : merged
        let value = stored
        lock.unlock()
        return value
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func reset() {
        lock.lock()
        stored = ""
        lock.unlock()
    }
}

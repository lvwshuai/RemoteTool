import Foundation

/// 把 `http(s)` 基址转成 `ws(s)` 基址。
///
/// `URLSessionWebSocketTask` 只认 `ws` / `wss`；直接塞 `http://` 的 URL 在部分系统版本上会
/// 建不出通道（Android 侧是手写握手，没有这个问题，所以它的 `replaceFirst("http","ws")` 是必需的）。
func webSocketBase(_ base: String) -> String {
    if base.hasPrefix("https://") {
        return "wss://" + String(base.dropFirst("https://".count))
    }
    if base.hasPrefix("http://") {
        return "ws://" + String(base.dropFirst("http://".count))
    }
    return base
}

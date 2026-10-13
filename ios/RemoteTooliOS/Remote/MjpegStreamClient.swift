import CoreGraphics
import Foundation
import ImageIO

/// MJPEG 兼容模式（`/api/stream/legacy`，`multipart/x-mixed-replace`）。
///
/// 对应 Android `RemoteActivity.readStream()`：扫描 `FF D8 … FF D9` 取出完整 JPEG 再解码。
/// 进入这条路径的场景与 Android 一致：旧服务端不支持 `format=h264`、或 H.264 连续解码失败。
final class MjpegStreamClient {
    private let url: String
    private let cookie: String

    private var stream: StreamingSession?
    private var frame = [UInt8]()
    private var previous = -1
    private var inFrame = false
    private var closed = false

    var onFrame: ((CGImage, Int, Int) -> Void)?
    var onError: ((Error) -> Void)?

    init(url: String, cookie: String) {
        self.url = url
        self.cookie = cookie
    }

    var receivedBytes: Int64 { stream?.receivedBytes ?? 0 }
    var frameCount: Int64 = 0

    func start() {
        guard !closed, stream == nil else { return }
        guard let target = URL(string: url) else { return }

        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.timeoutInterval = 600
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.setValue("multipart/x-mixed-replace", forHTTPHeaderField: "Accept")

        let session = StreamingSession(acceptedContentTypes: ["multipart/x-mixed-replace", "multipart"]) { [weak self] data in
            self?.consume(data)
        } onFinish: { [weak self] error in
            guard let self, !self.closed else { return }
            self.stream = nil
            if let error { self.onError?(error) }
        }
        stream = session
        session.start(request)
    }

    func close() {
        closed = true
        stream?.cancel()
        stream = nil
        frame.removeAll()
        inFrame = false
        previous = -1
    }

    private func consume(_ data: Data) {
        for byte in data {
            let value = Int(byte)

            if !inFrame {
                if previous == 0xFF, value == 0xD8 {
                    inFrame = true
                    frame.removeAll(keepingCapacity: true)
                    frame.append(0xFF)
                    frame.append(0xD8)
                }
                previous = value
                continue
            }

            frame.append(byte)
            if previous == 0xFF, value == 0xD9 {
                emit()
                inFrame = false
                frame.removeAll(keepingCapacity: true)
            } else if frame.count > 10_000_000 {
                // 与 Android 一样：超过 10 MB 仍未闭合就放弃这一帧，避免内存被无边界增长吃掉。
                inFrame = false
                frame.removeAll(keepingCapacity: true)
            }
            previous = value
        }
    }

    private func emit() {
        let payload = Data(frame)
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        frameCount += 1
        onFrame?(image, image.width, image.height)
    }
}

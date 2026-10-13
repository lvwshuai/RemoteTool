import AVFoundation
import Foundation

/// 远程桌面视频流：NAL 分帧 → 访问单元组装 → VideoToolbox 解码 → 显示层。
///
/// 对应 Android `H264Decoder.java`：
/// - `read()` 里那段「累计零字节 + 遇到 00 00 01 起始码就切 NAL」的扫描逻辑逐行照搬
///   （`zeros` / `began` / `nal` 三个状态变量语义完全一致）。
/// - `accept(nal)` 的分支顺序也是照搬的：**先按 AUD（type 9）提交上一个访问单元并重置**，
///   再记录 SPS/PPS、必要时 configure、最后把 NAL 追加进当前访问单元。
///   这个顺序保证访问单元以 AUD 开头，也正是服务端 `-bsf:v h264_metadata=aud=insert` 提供的边界。
final class H264StreamClient {
    private let url: String
    private let cookie: String
    private let displayLayer: AVSampleBufferDisplayLayer

    private var stream: StreamingSession?
    private var decoder: VideoToolboxDecoder?

    // NAL 扫描状态（对应 H264Decoder.read 的局部变量）
    private var zeros = 0
    private var nal: [UInt8] = []
    private var began = false
    private var nalBytes = 0

    // 访问单元组装状态（对应 H264Decoder 的字段）
    private var sps: Data?
    private var pps: Data?
    private var accessUnit: [Data] = []
    private var accessUnitBytes = 0
    private var hasSlice = false
    private var hasIDR = false
    private var configured = false
    private var closed = false

    var onSizeChange: ((Int, Int) -> Void)?
    var onFirstFrame: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    /// 服务端在响应头里回传的实际采集方式：`ddagrab`（DXGI 零拷贝）或 `gdigrab`。
    var onCaptureMethod: ((String) -> Void)?

    init(url: String, cookie: String, displayLayer: AVSampleBufferDisplayLayer) {
        self.url = url
        self.cookie = cookie
        self.displayLayer = displayLayer
    }

    var renderedFrames: Int64 { decoder?.renderedFrames ?? 0 }
    var receivedBytes: Int64 { stream?.receivedBytes ?? 0 }
    var lastFrameAt: TimeInterval { decoder?.lastFrameAt ?? 0 }
    var captureMethod: String? { stream?.responseHeader("X-Capture-Method") }

    // MARK: - 生命周期

    func start() {
        guard !closed, stream == nil, let request = makeRequest() else { return }

        let decoder = VideoToolboxDecoder(displayLayer: displayLayer)
        decoder.onSizeChange = { [weak self] width, height in self?.onSizeChange?(width, height) }
        decoder.onFirstFrame = { [weak self] hardware in self?.onFirstFrame?(hardware) }
        decoder.onError = { [weak self] error in self?.onError?(error) }
        self.decoder = decoder

        let session = StreamingSession(acceptedContentTypes: ["video/h264"]) { [weak self] data in
            self?.consume(data)
        } onFinish: { [weak self] error in
            guard let self, !self.closed else { return }
            self.stream = nil
            if let error { self.onError?(error) }
        }
        stream = session
        session.start(request)

        // 采集方式要等响应头到达，稍微延后一点上报。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let method = self.captureMethod else { return }
            self.onCaptureMethod?(method)
        }
    }

    func close() {
        closed = true
        stream?.cancel()
        stream = nil
        decoder?.close()
        decoder = nil
        resetAssembly()
    }

    private func makeRequest() -> URLRequest? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        // 长连接不要设请求超时，靠上层看门狗判断是否停出帧。
        request.timeoutInterval = 600
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.setValue("video/h264, multipart/x-mixed-replace", forHTTPHeaderField: "Accept")
        return request
    }

    private func resetAssembly() {
        zeros = 0
        nal.removeAll(keepingCapacity: true)
        nalBytes = 0
        began = false
        accessUnit.removeAll(keepingCapacity: true)
        accessUnitBytes = 0
        hasSlice = false
        hasIDR = false
    }

    // MARK: - Annex B 扫描（逐行对应 H264Decoder.read 的内层循环）

    private func consume(_ data: Data) {
        for byte in data {
            let value = Int(byte)

            if value == 0 {
                zeros += 1
                continue
            }
            if value == 1, zeros >= 2 {
                if began, nalBytes > 0 { accept(nal) }
                nal.removeAll(keepingCapacity: true)
                nalBytes = 0
                began = true
                zeros = 0
                continue
            }
            if began {
                var pending = zeros
                while pending > 0 {
                    nal.append(0)
                    nalBytes += 1
                    pending -= 1
                }
                nal.append(byte)
                nalBytes += 1
                if nalBytes > 8_000_000 {
                    onError?(NSError(domain: "RemoteTool.Video", code: -11,
                                     userInfo: [NSLocalizedDescriptionKey: "单个 NAL 过大，画面流已失效"]))
                    return
                }
            }
            zeros = 0
        }
    }

    // MARK: - 访问单元组装（逐行对应 H264Decoder.accept / submit）

    private func accept(_ unit: [UInt8]) {
        guard let first = unit.first else { return }
        let type = Int(first & 0x1F)

        if type == 9 {
            submit()
            accessUnit.removeAll(keepingCapacity: true)
            accessUnitBytes = 0
            hasSlice = false
            hasIDR = false
        }
        if type == 7 { sps = Data(unit) }
        if type == 8 { pps = Data(unit) }

        if !configured, let sps, let pps {
            decoder?.configure(sps: sps, pps: pps)
            configured = true
        }

        accessUnit.append(Data(unit))
        accessUnitBytes += unit.count
        if type == 1 || type == 5 { hasSlice = true }
        if type == 5 { hasIDR = true }

        if accessUnitBytes > 10_000_000 {
            onError?(NSError(domain: "RemoteTool.Video", code: -12,
                             userInfo: [NSLocalizedDescriptionKey: "访问单元过大，画面流已失效"]))
        }
    }

    private func submit() {
        guard !closed, configured, hasSlice, !accessUnit.isEmpty, let decoder else { return }
        decoder.decode(accessUnit: accessUnit, isIDR: hasIDR)
    }
}

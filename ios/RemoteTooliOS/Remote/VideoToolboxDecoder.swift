import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// H.264 硬件解码 + 零缓冲渲染。
///
/// 对应 Android `H264Decoder` 里的 `MediaCodec` + `SurfaceTexture` + `releaseOutputBuffer(render: true)`。
///
/// iOS 侧的对应关系：
/// - `MediaCodec` → `VTDecompressionSession`
/// - `Surface`/`TextureView` → `AVSampleBufferDisplayLayer`
/// - `MediaFormat.createVideoFormat` + `csd-0/csd-1` → `CMVideoFormatDescriptionCreateFromH264ParameterSets`
///
/// 关键点：**解码后的图像直接 enqueue 给 `AVSampleBufferDisplayLayer`，中间不落任何缓冲**，
/// 并且打上 `DisplayImmediately` 附件。绝对不要换成 `AVPlayer`——它有自带的播放缓冲，
/// 会把延迟推到秒级，这是远程桌面最不能接受的。
final class VideoToolboxDecoder {
    /// 时间基取 60000、步长 1000，正好是 60fps；与 Android 的 `pts += 16667`（微秒）等价。
    private let timeScale: Int32 = 60_000
    private let frameStep: Int64 = 1_000

    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var pts: Int64 = 0
    private var closed = false

    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var renderedFrames: Int64 = 0
    private(set) var lastFrameAt: TimeInterval = 0
    private(set) var isHardwareAccelerated = false
    private(set) var droppedFrames: Int64 = 0

    private weak var displayLayer: AVSampleBufferDisplayLayer?

    /// 首帧渲染完成（参数表示是否走了硬件解码路径）。
    var onFirstFrame: ((Bool) -> Void)?
    /// 解码输出尺寸变化。
    var onSizeChange: ((Int, Int) -> Void)?
    /// 解码或渲染失败，上层据此触发重连或回退到 MJPEG。
    var onError: ((Error) -> Void)?

    private var firstFrameReported = false

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    // MARK: - 参数集与解码器

    /// 收到 SPS / PPS 后建会话。与 Android 一样，只有两个参数集都到齐才 configure。
    func configure(sps: Data, pps: Data) {
        lock.lock()
        self.sps = sps
        self.pps = pps
        if session != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        var description: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw -> OSStatus in
            guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                var pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                var sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                    sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description)
                    }
                }
            }
        }

        guard status == noErr, let description else {
            reportError(NSError(domain: "RemoteTool.Video", code: Int(status),
                                userInfo: [NSLocalizedDescriptionKey: "SPS/PPS 无法生成解码格式描述（\(status)）"]))
            return
        }

        // 优先硬件解码，但不强制：旧机型 / 异常配置下允许 VideoToolbox 自行降级到软件路径。
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: false
        ]
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var created: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created)

        guard createStatus == noErr, let created else {
            reportError(NSError(domain: "RemoteTool.Video", code: Int(createStatus),
                                userInfo: [NSLocalizedDescriptionKey: "无法创建 H.264 解码会话（\(createStatus)）"]))
            return
        }

        // RealTime：不做帧重排与多帧缓存。服务端已经用 `-bf 0 -tune zerolatency` 保证无 B 帧。
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let size = (Int(dimensions.width), Int(dimensions.height))

        var usingHardware: CFTypeRef?
        let hardwareStatus = VTSessionCopyProperty(
            created,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault,
            valueOut: &usingHardware)
        // 读不到该属性时按硬件路径报告：iOS 上 1080p60 纯软解不可能流畅，报「软件解码」会误导排查。
        let hardware = hardwareStatus == noErr ? ((usingHardware as? Bool) ?? true) : true

        lock.lock()
        session = created
        formatDescription = description
        isHardwareAccelerated = hardware
        if size.0 > 0, size.1 > 0 {
            width = size.0
            height = size.1
        }
        lock.unlock()

        if size.0 > 0, size.1 > 0 {
            DispatchQueue.main.async { [weak self] in self?.onSizeChange?(size.0, size.1) }
        }
    }

    var isConfigured: Bool {
        lock.lock(); defer { lock.unlock() }
        return session != nil
    }

    var decodedWidth: Int { lock.withLockValue { width } }
    var decodedHeight: Int { lock.withLockValue { height } }

    // MARK: - 解码

    /// 提交一个完整访问单元（AVCC 前的 NAL 数组，不含起始码）。
    func decode(accessUnit: [Data], isIDR: Bool) {
        lock.lock()
        guard !closed, let session, let formatDescription else {
            lock.unlock()
            return
        }
        let currentPts = pts
        pts += frameStep
        lock.unlock()

        guard let sampleBuffer = makeSampleBuffer(accessUnit: accessUnit,
                                                  formatDescription: formatDescription,
                                                  presentationTime: currentPts,
                                                  isIDR: isIDR) else {
            reportError(NSError(domain: "RemoteTool.Video", code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "访问单元无法封装成样本缓冲"]))
            return
        }

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil) { [weak self] status, _, imageBuffer, presentationTime, _ in
                guard let self else { return }
                if status != noErr {
                    if status != kVTVideoDecoder_MallocFailedErr {
                        self.reportError(NSError(domain: "RemoteTool.Video", code: Int(status),
                                                 userInfo: [NSLocalizedDescriptionKey: "H.264 解码失败（\(status)）"]))
                    }
                    return
                }
                guard let imageBuffer else { return }
                self.enqueue(imageBuffer: imageBuffer, presentationTime: presentationTime)
            }

        if decodeStatus != noErr {
            reportError(NSError(domain: "RemoteTool.Video", code: Int(decodeStatus),
                                userInfo: [NSLocalizedDescriptionKey: "提交解码失败（\(decodeStatus)）"]))
        }
    }

    private func makeSampleBuffer(accessUnit: [Data],
                                  formatDescription: CMVideoFormatDescription,
                                  presentationTime: Int64,
                                  isIDR: Bool) -> CMSampleBuffer? {
        let totalLength = accessUnit.reduce(0) { $0 + 4 + $1.count }
        guard totalLength > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLength,
            flags: 0,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        var offset = 0
        for nal in accessUnit {
            guard !nal.isEmpty else { continue }
            // AVCC 格式：每个 NAL 前置 4 字节大端长度。
            var length = UInt32(nal.count).bigEndian
            let lengthStatus = withUnsafeBytes(of: &length) { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer,
                                                     offsetIntoDestination: offset, dataLength: 4)
            }
            guard lengthStatus == kCMBlockBufferNoErr else { return nil }
            offset += 4

            let payloadStatus = nal.withUnsafeBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer,
                                                     offsetIntoDestination: offset, dataLength: nal.count)
            }
            guard payloadStatus == kCMBlockBufferNoErr else { return nil }
            offset += nal.count
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: frameStep, timescale: timeScale),
            presentationTimeStamp: CMTime(value: presentationTime, timescale: timeScale),
            decodeTimeStamp: .invalid)
        var sampleSize = totalLength

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return nil }

        if !isIDR {
            CMSetAttachment(sampleBuffer,
                            key: kCMSampleAttachmentKey_NotSync,
                            value: kCFBooleanTrue,
                            attachmentMode: .shouldPropagate)
        }
        return sampleBuffer
    }

    private func enqueue(imageBuffer: CVImageBuffer, presentationTime: CMTime) {
        guard let displayLayer else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
            if displayLayer.status == .failed {
                reportError(NSError(domain: "RemoteTool.Video", code: -3,
                                    userInfo: [NSLocalizedDescriptionKey: "显示层已失败，需要重建画面"]))
                return
            }
        }
        // 显示层来不及消费时直接丢这一帧，而不是堆积——积压比丢帧更影响手感。
        guard displayLayer.isReadyForMoreMediaData else {
            lock.lock(); droppedFrames += 1; lock.unlock()
            return
        }

        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &description) == noErr, let description else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: presentationTime,
                                       decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return }

        CMSetAttachment(sampleBuffer,
                        key: kCMSampleBufferAttachmentKey_DisplayImmediately,
                        value: kCFBooleanTrue,
                        attachmentMode: .shouldNotPropagate)

        displayLayer.enqueue(sampleBuffer)

        lock.lock()
        renderedFrames += 1
        lastFrameAt = Date().timeIntervalSince1970
        let shouldReport = !firstFrameReported
        firstFrameReported = true
        let hardware = isHardwareAccelerated
        lock.unlock()

        if shouldReport {
            DispatchQueue.main.async { [weak self] in self?.onFirstFrame?(hardware) }
        }
    }

    private func reportError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    // MARK: - 生命周期

    /// 只重置时间戳与统计，保留解码会话（参数集不变时可以少一次重建）。
    func resetTimeline() {
        lock.lock()
        pts = 0
        renderedFrames = 0
        droppedFrames = 0
        lastFrameAt = 0
        firstFrameReported = false
        lock.unlock()
    }

    func close() {
        lock.lock()
        let existing = session
        session = nil
        formatDescription = nil
        sps = nil
        pps = nil
        closed = true
        lock.unlock()

        if let existing {
            VTDecompressionSessionWaitForAsynchronousFrames(existing)
            VTDecompressionSessionInvalidate(existing)
        }
        displayLayer?.flushAndRemoveImage()
    }
}

private extension NSLock {
    func withLockValue<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

import AVFoundation
import UIKit

/// 画面舞台：H.264 解码层与 MJPEG 图片共用同一套「等比适配 + 缩放 + 平移」几何。
///
/// 对应 Android `RemoteActivity.RemoteView`：`destination()` 的适配与 pan 夹取逻辑逐行照搬，
/// 只是 Android 用 `Matrix.setScale/postTranslate` 变换 TextureView，
/// iOS 直接把 `AVSampleBufferDisplayLayer` 的 frame 摆到同一矩形上 —— 结果一致但少一层矩阵，
/// 也避免了 `AVSampleBufferDisplayLayer` 与父层变换叠加时的模糊。
final class VideoStageView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let imageLayer = CALayer()

    private(set) var zoom: CGFloat = 1
    private(set) var panX: CGFloat = 0
    private(set) var panY: CGFloat = 0

    /// 当前媒体的像素尺寸（H.264 用解码输出尺寸，MJPEG 用 JPEG 尺寸）。
    private(set) var mediaSize: CGSize = .zero
    private(set) var isVideoMode = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 5 / 255, green: 10 / 255, blue: 17 / 255, alpha: 1)
        isUserInteractionEnabled = false

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.clear.cgColor
        layer.addSublayer(displayLayer)

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.masksToBounds = true
        imageLayer.isHidden = true
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLayout()
    }

    // MARK: - 模式与尺寸

    func setMediaSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let size = CGSize(width: width, height: height)
        guard size != mediaSize else { return }
        mediaSize = size
        setNeedsLayout()
    }

    func setVideoMode(_ on: Bool) {
        guard on != isVideoMode else { return }
        isVideoMode = on
        imageLayer.isHidden = on
        displayLayer.isHidden = !on
        if on { imageLayer.contents = nil }
        setNeedsLayout()
    }

    func showImage(_ image: CGImage?, size: CGSize) {
        guard isVideoMode == false else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        setMediaSize(width: Int(size.width), height: Int(size.height))
    }

    // MARK: - 几何（对应 RemoteView.destination）

    /// 等比适配矩形，含缩放与平移；会顺便把 pan 夹回可视范围（与 Android 一致的副作用）。
    @discardableResult
    func destinationRect() -> CGRect {
        let width = mediaSize.width
        let height = mediaSize.height
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }

        let fit = min(bounds.width / width, bounds.height / height)
        let scaledWidth = width * fit * zoom
        let scaledHeight = height * fit * zoom
        let maxX = max(0, (scaledWidth - bounds.width) / 2)
        let maxY = max(0, (scaledHeight - bounds.height) / 2)
        panX = min(max(panX, -maxX), maxX)
        panY = min(max(panY, -maxY), maxY)
        return CGRect(x: (bounds.width - scaledWidth) / 2 + panX,
                      y: (bounds.height - scaledHeight) / 2 + panY,
                      width: scaledWidth,
                      height: scaledHeight)
    }

    private func applyLayout() {
        let rect = destinationRect()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = rect
        imageLayer.frame = rect
        CATransaction.commit()
    }

    /// 把视图坐标换算成远程桌面的归一化坐标（0…1）。对应 `RemoteView.point()`。
    func normalizedPoint(_ point: CGPoint) -> CGPoint? {
        let rect = destinationRect()
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    func contains(_ point: CGPoint) -> Bool {
        destinationRect().contains(point)
    }

    // MARK: - 缩放与平移

    func resetZoom() {
        zoom = 1
        panX = 0
        panY = 0
        setNeedsLayout()
    }

    func pan(by dx: CGFloat, dy: CGFloat) {
        panX += dx
        panY += dy
        setNeedsLayout()
    }

    /// 张合缩放。公式与 Android `RemoteView` 的 ACTION_MOVE 分支完全一致，
    /// 保证缩放中心跟随双指中点、并叠加中点位移。
    func applyPinch(startZoom: CGFloat, startDistance: CGFloat, distance: CGFloat,
                    mid: CGPoint, previousMid: CGPoint) {
        let before = zoom
        let target = min(max(startZoom * distance / max(startDistance, 1), 1), 5)
        guard target != before else {
            panX += mid.x - previousMid.x
            panY += mid.y - previousMid.y
            setNeedsLayout()
            return
        }
        zoom = target
        let ratio = target / before
        let centerX = bounds.width / 2
        let centerY = bounds.height / 2
        panX = (mid.x - centerX) - (mid.x - centerX - panX) * ratio
        panY = (mid.y - centerY) - (mid.y - centerY - panY) * ratio
        panX += mid.x - previousMid.x
        panY += mid.y - previousMid.y
        setNeedsLayout()
    }

    /// 触控板模式最后会把位移除以 fit 换算到远程桌面像素，这里复用同一 fit。
    var fitScale: CGFloat {
        guard mediaSize.width > 0, mediaSize.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / mediaSize.width, bounds.height / mediaSize.height)
    }

    func reset() {
        zoom = 1
        panX = 0
        panY = 0
        mediaSize = .zero
        imageLayer.contents = nil
        displayLayer.flushAndRemoveImage()
        setNeedsLayout()
    }
}

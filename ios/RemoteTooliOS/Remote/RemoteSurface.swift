import SwiftUI
import UIKit

/// 远程画面容器：解码层 + 触摸面 + 连接中的占位文字。
final class RemoteSurfaceView: UIView {
    let stage = VideoStageView()
    let touch = TouchSurfaceView()
    private let placeholder = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 5 / 255, green: 10 / 255, blue: 17 / 255, alpha: 1)
        addSubview(stage)
        addSubview(touch)

        placeholder.text = "正在连接远程画面…"
        placeholder.textColor = UIColor(red: 154 / 255, green: 174 / 255, blue: 195 / 255, alpha: 1)
        placeholder.font = .systemFont(ofSize: 18)
        placeholder.numberOfLines = 1
        addSubview(placeholder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        stage.frame = bounds
        touch.frame = bounds
        placeholder.sizeToFit()
        // 与 Android RemoteView.onDraw 一致：左边距 dp(24)，垂直居中。
        placeholder.frame.origin = CGPoint(x: 24,
                                          y: bounds.midY - placeholder.bounds.height / 2)
    }

    func setPlaceholderVisible(_ visible: Bool) {
        placeholder.isHidden = !visible
    }
}

/// 把 UIView 层的触摸意图转成控制器调用。
struct RemoteSurface: UIViewRepresentable {
    @ObservedObject var controller: RemoteController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> RemoteSurfaceView {
        let view = RemoteSurfaceView()
        view.touch.delegate = context.coordinator
        // 触摸面需要知道画面矩形（用于判定「点在画面内 / 画面外」和换算归一化坐标），
        // 这块在 Android 里是 RemoteView 自己持有，iOS 拆成了两个视图，所以要显式接上。
        view.touch.stage = view.stage
        controller.attach(stage: view.stage, touch: view.touch)
        return view
    }

    func updateUIView(_ view: RemoteSurfaceView, context: Context) {
        context.coordinator.controller = controller
        view.touch.isTrackpad = controller.isTrackpad
        // 出画后撤掉占位文字；回退到 MJPEG 时同样由首帧控制。
        view.setPlaceholderVisible(!controller.hasVideoFrame)
    }

    final class Coordinator: NSObject, TouchSurfaceDelegate {
        var controller: RemoteController

        init(controller: RemoteController) {
            self.controller = controller
        }

        func touchSurfaceDidRequestToolToggle(_ view: TouchSurfaceView) {
            controller.toggleTools()
        }

        func touchSurfaceDidBeginInteraction(_ view: TouchSurfaceView) {
            controller.beginInteraction()
        }

        func touchSurface(_ view: TouchSurfaceView, didMoveCursorTo point: CGPoint) {
            controller.sendCursorMove(to: point)
        }

        func touchSurface(_ view: TouchSurfaceView, didPressButton button: Int) {
            controller.sendPress(button: button)
        }

        func touchSurface(_ view: TouchSurfaceView, didReleaseButton button: Int) {
            controller.sendRelease(button: button)
        }

        func touchSurface(_ view: TouchSurfaceView, didClickButton button: Int) {
            controller.sendClick(button: button)
        }

        func touchSurface(_ view: TouchSurfaceView, didMoveRelativeX dx: CGFloat, y dy: CGFloat) {
            controller.handleRelativeMove(dx: Double(dx), dy: Double(dy))
        }

        func touchSurface(_ view: TouchSurfaceView, didWheel delta: Int) {
            controller.sendWheel(delta: delta)
        }

        func touchSurface(_ view: TouchSurfaceView, didTwoFingerScroll delta: Int) {
            controller.sendTwoFingerScroll(delta: delta)
        }
    }
}

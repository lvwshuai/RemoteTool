import UIKit

/// 触摸面板的意图回调。所有坐标都是远程桌面的归一化坐标（0…1）。
protocol TouchSurfaceDelegate: AnyObject {
    /// 点击画面外空白 → 切换工具栏（对应 Android `toggleTools()`）。
    func touchSurfaceDidRequestToolToggle(_ view: TouchSurfaceView)
    /// 手指落在画面上 → 取消工具栏自动隐藏计时（对应 `ui.removeCallbacks(hideTools); hideTools.run()`）。
    func touchSurfaceDidBeginInteraction(_ view: TouchSurfaceView)
    func touchSurface(_ view: TouchSurfaceView, didMoveCursorTo point: CGPoint)
    func touchSurface(_ view: TouchSurfaceView, didPressButton button: Int)
    func touchSurface(_ view: TouchSurfaceView, didReleaseButton button: Int)
    func touchSurface(_ view: TouchSurfaceView, didClickButton button: Int)
    /// 触控板相对位移（已按 fit 换算到远程桌面像素）。
    func touchSurface(_ view: TouchSurfaceView, didMoveRelativeX dx: CGFloat, y dy: CGFloat)
    /// 工具栏按钮触发的滚轮（正=上滚）。
    func touchSurface(_ view: TouchSurfaceView, didWheel delta: Int)
    /// 双指上下滑产生的滚轮。线格式与 Android 一致：`{"type":"pointer-wheel","x":0,"y":0,"dy":delta}`。
    func touchSurface(_ view: TouchSurfaceView, didTwoFingerScroll delta: Int)
}

/// 触摸面。逐条对应 Android `RemoteView.onTouchEvent`：
///
/// - 落在画面外 → 切工具栏并吞掉整个手势
/// - 落在画面内 → 隐藏工具栏（配合自动隐藏计时）
/// - 长按 550 ms → 右键
/// - 拖动超过阈值：放大状态下平移画面；触控板模式发相对位移；直接触控模式发 mouse-down/mouse-move/mouse-up
/// - 双指：张合缩放 / 上下滑滚轮 / 放大后平移（由 `TwoFingerGesture` 锁定模式）
/// - 抬起：拖动 → mouse-up；未拖动 → 左键点击
final class TouchSurfaceView: UIView {
    weak var stage: VideoStageView?
    weak var delegate: TouchSurfaceDelegate?

    /// 触控板模式：拖动只发相对位移，不移动光标位置（对应 Android `trackpad`）。
    var isTrackpad = false

    /// 直接触控模式下拖动多少点才算拖动（Android 为 dp(7)），触控板为 dp(2)。
    private let directDragThreshold: CGFloat = 7
    private let trackpadDragThreshold: CGFloat = 2
    private let longPressDelay: TimeInterval = 0.55
    private let moveThrottle: TimeInterval = 0.025

    private var startPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var dragging = false
    private var longPress = false
    private var twoFinger = false
    private var panGesture = false
    private var toolbarGesture = false

    private var rightHoldWork: DispatchWorkItem?
    private var lastMoveTime: TimeInterval = 0
    private var cursor = CGPoint(x: 0.5, y: 0.5)

    private lazy var twoFingerGesture = TwoFingerGesture(threshold: 8, step: 20)
    private var pinchStartDistance: CGFloat = 1
    private var pinchStartZoom: CGFloat = 1
    private var pinchPreviousMid: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 触摸

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = activeTouches(event)
        if active.count >= 2 {
            beginTwoFinger(active)
            return
        }
        guard let touch = touches.first, !twoFinger else { return }

        let point = touch.location(in: self)
        toolbarGesture = !(stage?.contains(point) ?? false)
        if toolbarGesture {
            delegate?.touchSurfaceDidRequestToolToggle(self)
            return
        }

        delegate?.touchSurfaceDidBeginInteraction(self)
        startPoint = point
        lastPoint = point
        dragging = false
        longPress = false
        panGesture = false
        scheduleRightHold(at: point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = activeTouches(event)

        if twoFinger {
            guard active.count >= 2 else { return }
            updateTwoFinger(active)
            return
        }
        if toolbarGesture { return }
        guard let touch = touches.first else { return }

        let point = touch.location(in: self)
        let dx = point.x - lastPoint.x
        let dy = point.y - lastPoint.y
        lastPoint = point

        let moved = hypot(point.x - startPoint.x, point.y - startPoint.y)
        let threshold = isTrackpad ? trackpadDragThreshold : directDragThreshold
        guard (dragging || moved > threshold), !longPress else { return }

        cancelRightHold()

        // 放大后单指平移画面（触控板除外，触控板始终发相对位移）。
        if (stage?.zoom ?? 1) > 1, !isTrackpad {
            dragging = true
            panGesture = true
            stage?.pan(by: dx, dy: dy)
            return
        }

        var moveX = dx
        var moveY = dy
        if !dragging, isTrackpad {
            // 第一次移动用相对起点的总位移，与 Android 一致。
            moveX = point.x - startPoint.x
            moveY = point.y - startPoint.y
        }
        if !dragging, !isTrackpad {
            updateCursor(startPoint)
            delegate?.touchSurface(self, didPressButton: 0)
        }
        dragging = true

        if isTrackpad {
            let fit = max(stage?.fitScale ?? 1, 0.0001)
            delegate?.touchSurface(self, didMoveRelativeX: moveX / fit, y: moveY / fit)
        } else {
            updateCursor(point)
            let now = CACurrentMediaTime()
            if now - lastMoveTime > moveThrottle {
                lastMoveTime = now
                delegate?.touchSurface(self, didMoveCursorTo: cursor)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = activeTouches(event)
        if !active.isEmpty {
            // 还有手指在屏幕上，等最后一次抬起再收尾。双指抬起阶段维持 twoFinger 标记。
            if twoFinger { return }
        }
        cancelRightHold()

        if twoFinger {
            twoFinger = false
            return
        }
        if toolbarGesture {
            toolbarGesture = false
            return
        }

        let point = touches.first.map { $0.location(in: self) } ?? lastPoint
        if dragging, !panGesture, !isTrackpad {
            delegate?.touchSurface(self, didReleaseButton: 0)
        } else if !dragging, !longPress {
            if !isTrackpad { updateCursor(point) }
            delegate?.touchSurface(self, didClickButton: 0)
        }
        dragging = false
        panGesture = false
        longPress = false
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelRightHold()
        if dragging, !panGesture, !isTrackpad {
            delegate?.touchSurface(self, didReleaseButton: 0)
        }
        dragging = false
        panGesture = false
        longPress = false
        twoFinger = false
        toolbarGesture = false
    }

    // MARK: - 双指

    private func beginTwoFinger(_ active: [UITouch]) {
        cancelRightHold()
        if dragging, !panGesture, !isTrackpad {
            delegate?.touchSurface(self, didReleaseButton: 0)
        }
        twoFinger = true
        let mid = midpoint(active)
        let distance = max(1, spread(active))
        pinchStartDistance = distance
        pinchStartZoom = stage?.zoom ?? 1
        pinchPreviousMid = mid
        twoFingerGesture.start(distance: Double(distance), x: Double(mid.x), y: Double(mid.y))
    }

    private func updateTwoFinger(_ active: [UITouch]) {
        guard let stage else { return }
        let mid = midpoint(active)
        let distance = spread(active)
        let delta = twoFingerGesture.update(distance: Double(distance),
                                            x: Double(mid.x),
                                            y: Double(mid.y))

        switch twoFingerGesture.mode {
        case .pinch:
            stage.applyPinch(startZoom: pinchStartZoom,
                             startDistance: pinchStartDistance,
                             distance: distance,
                             mid: mid,
                             previousMid: pinchPreviousMid)
        case .scroll:
            if delta != 0 { delegate?.touchSurface(self, didTwoFingerScroll: delta) }
        case .pan:
            if stage.zoom > 1 {
                stage.pan(by: mid.x - pinchPreviousMid.x, dy: mid.y - pinchPreviousMid.y)
            }
        case .undecided:
            break
        }
        pinchPreviousMid = mid
    }

    private func activeTouches(_ event: UIEvent?) -> [UITouch] {
        guard let all = event?.allTouches else { return [] }
        return all.filter { $0.phase == .began || $0.phase == .moved || $0.phase == .stationary }
    }

    private func midpoint(_ touches: [UITouch]) -> CGPoint {
        guard touches.count >= 2 else { return .zero }
        let first = touches[0].location(in: self)
        let second = touches[1].location(in: self)
        return CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    private func spread(_ touches: [UITouch]) -> CGFloat {
        guard touches.count >= 2 else { return 0 }
        let first = touches[0].location(in: self)
        let second = touches[1].location(in: self)
        return hypot(first.x - second.x, first.y - second.y)
    }

    // MARK: - 光标与右键

    private func updateCursor(_ point: CGPoint) {
        guard let normalized = stage?.normalizedPoint(point) else { return }
        cursor = normalized
    }

    private func scheduleRightHold(at point: CGPoint) {
        cancelRightHold()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.dragging, !self.twoFinger else { return }
            self.longPress = true
            if !self.isTrackpad { self.updateCursor(point) }
            self.delegate?.touchSurface(self, didClickButton: 2)
        }
        rightHoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay, execute: work)
    }

    private func cancelRightHold() {
        rightHoldWork?.cancel()
        rightHoldWork = nil
    }

    /// 工具栏按钮点击（左键 / 右键 / 滚轮）使用最近一次光标位置。
    var currentCursor: CGPoint { cursor }

    /// 工具栏按钮触发的滚轮。
    func sendWheel(_ delta: Int, at point: CGPoint? = nil) {
        if let point, !isTrackpad { updateCursor(point) }
        delegate?.touchSurface(self, didWheel: delta)
    }

    func sendClick(button: Int, at point: CGPoint? = nil) {
        if let point, !isTrackpad { updateCursor(point) }
        delegate?.touchSurface(self, didClickButton: button)
    }
}

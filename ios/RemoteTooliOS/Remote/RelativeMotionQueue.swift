import Foundation

/// 相对鼠标位移队列。逐行对应 Android `RelativeMotionQueue.java`。
///
/// 设计意图（原文注释）：**只保留一个在途发送者**，把触摸位移累计起来，
/// 保留未满 1 像素的小数部分，而不是把每个 `ACTION_MOVE` 都排进队列。
/// 这样才能在停止手指移动后不出现「回放积压事件」的跟手感问题。
final class RelativeMotionQueue {
    private let lock = NSLock()
    private var x: Double = 0
    private var y: Double = 0
    private var scheduled = false

    /// 累加位移。返回 true 表示调用方应当启动发送循环（当前没有在途发送者且已满 1 像素）。
    func offer(_ dx: Double, _ dy: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        x += dx
        y += dy
        if scheduled || (Int(x) == 0 && Int(y) == 0) { return false }
        scheduled = true
        return true
    }

    /// 取出一批位移；返回 nil 表示当前无待发送位移，发送循环应当结束。
    func take() -> (dx: Int, dy: Int)? {
        lock.lock()
        defer { lock.unlock() }
        let dx = min(max(Int(x), -4096), 4096)
        let dy = min(max(Int(y), -4096), 4096)
        if dx == 0 && dy == 0 {
            scheduled = false
            return nil
        }
        x -= Double(dx)
        y -= Double(dy)
        return (dx, dy)
    }

    func reset() {
        lock.lock()
        x = 0
        y = 0
        scheduled = false
        lock.unlock()
    }
}

/// 双指手势判别。逐行对应 Android `TwoFingerGesture.java`。
///
/// 一次双指手势在越过阈值后会被**锁定**成滚轮 / 缩放 / 平移之一，
/// 避免同一段手指移动既滚又缩的抖动。
final class TwoFingerGesture {
    enum Mode {
        case undecided
        case scroll
        case pinch
        case pan
    }

    private(set) var mode: Mode = .undecided
    private let threshold: Double
    private let step: Double
    private var startDistance: Double = 0
    private var startX: Double = 0
    private var startY: Double = 0
    private var lastY: Double = 0
    private var accumulated: Double = 0

    /// - Parameters:
    ///   - threshold: 判定阈值（Android 传 dp(8)）
    ///   - step: 一格滚轮对应的手指位移（Android 传 dp(20)）
    init(threshold: Double, step: Double) {
        self.threshold = threshold
        self.step = step
    }

    func start(distance: Double, x: Double, y: Double) {
        mode = .undecided
        startDistance = distance
        startX = x
        startY = y
        lastY = y
        accumulated = 0
    }

    /// 返回本次应当发送的滚轮增量（单位同 WHEEL_DELTA，120 为一格）；非滚轮模式返回 0。
    func update(distance: Double, x: Double, y: Double) -> Int {
        let dx = abs(x - startX)
        let dy = abs(y - startY)
        let spread = abs(distance - startDistance)

        if mode == .undecided {
            if spread >= threshold, spread >= max(dx, dy) * 0.75 {
                mode = .pinch
            } else if dy >= threshold, dy >= dx * 1.25, spread < threshold * 1.5 {
                mode = .scroll
                accumulated = y - startY
            } else if dx >= threshold {
                mode = .pan
            }
        } else if mode == .scroll {
            accumulated += y - lastY
        }
        lastY = y

        guard mode == .scroll else { return 0 }
        let ticks = min(max(Int(accumulated / step), -6), 6)
        accumulated -= Double(ticks) * step
        return ticks * 120
    }
}

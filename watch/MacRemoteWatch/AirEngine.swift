import CoreMotion
import Foundation
import WatchKit

/// 体感参数（从设置里读，主线程写、传感器线程读，用锁保护）
struct AirConfig {
    var gain = 14.0              // 像素 / 度
    var invertX = false
    var invertY = false
    var autoPause = true         // 手臂垂下时暂停
    var pinchEnabled = true      // 实验：捏一下 = 左键
    var pinchThreshold = 0.08    // 捏合检测阈值（g / 采样），越小越灵敏
    var crownTowardHand = true   // 表冠朝向手掌一侧（默认戴法）
}

/// 读取手表的陀螺仪和加速度计：
/// - 转动手腕 → 光标移动（用重力换算到真实世界的「左右 / 上下」，和网页版同一套算法）
/// - 检测「拇指和食指捏一下」在手腕上产生的细微冲击 → 左键（实验功能）
final class AirEngine {
    private let mm = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private let lock = NSLock()
    private var cfg = AirConfig()
    private var paused = false

    // 传感器线程上的状态
    private var fx = 0.0, fy = 0.0
    private var lastTimestamp: TimeInterval = 0
    private var prevAccel: CMAcceleration?
    private var lastPinchAt: TimeInterval = 0
    private var peak = 0.0
    private var lastPeakReport: TimeInterval = 0

    let sender: Sender
    /// 检测到一次捏合（主线程回调）
    var onPinch: (() -> Void)?
    /// 最近的冲击强度，给设置页面调阈值用（主线程回调）
    var onPeak: ((Double) -> Void)?
    /// 手臂垂下自动暂停的状态变化（主线程回调）
    var onArmDown: ((Bool) -> Void)?
    private var armDown = false

    var isAvailable: Bool { mm.isDeviceMotionAvailable }

    init(sender: Sender) { self.sender = sender }

    func update(_ c: AirConfig) { lock.lock(); cfg = c; lock.unlock() }
    func setPaused(_ p: Bool) { lock.lock(); paused = p; lock.unlock() }

    func start() {
        guard mm.isDeviceMotionAvailable, !mm.isDeviceMotionActive else { return }
        mm.deviceMotionUpdateInterval = 1.0 / 100.0
        mm.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
            if let m = m { self?.process(m) }
        }
    }

    func stop() { mm.stopDeviceMotionUpdates() }

    private func process(_ m: CMDeviceMotion) {
        lock.lock(); let c = cfg; let isPaused = paused; lock.unlock()

        let dt = lastTimestamp > 0 ? min(max(m.timestamp - lastTimestamp, 0.004), 0.05) : 0.01
        lastTimestamp = m.timestamp
        let toDeg = 180.0 / Double.pi
        let w = [m.rotationRate.x * toDeg, m.rotationRate.y * toDeg, m.rotationRate.z * toDeg]

        // 世界「上」在手表坐标系里的方向（CoreMotion 的 gravity 指向地面）
        let gn = sqrt(m.gravity.x * m.gravity.x + m.gravity.y * m.gravity.y + m.gravity.z * m.gravity.z)
        let u = gn > 0.1 ? [-m.gravity.x / gn, -m.gravity.y / gn, -m.gravity.z / gn] : [0, 0, 1]
        // 小臂指向：手表 x 轴（表冠那一侧）朝手掌时为 +x
        let p = [c.crownTowardHand ? 1.0 : -1.0, 0, 0]

        let yaw = dot(w, u)                          // 绕竖直轴：正 = 向左转
        var axis = cross(p, u)                       // 抬手（小臂指向上方）对应的转轴
        let an = norm(axis)
        axis = an > 0.3 ? axis.map { $0 / an } : [0, -1, 0]
        let pitch = dot(w, axis)                     // 正 = 抬手

        // 手臂垂下（小臂指向地面）时自动暂停，相当于把鼠标提起来
        let down = c.autoPause && dot(p, u) < -0.75
        if down != armDown {
            armDown = down
            let cb = onArmDown
            DispatchQueue.main.async { cb?(down) }
        }

        detectPinch(m, rot: norm(w), c: c)

        guard !isPaused, !down else { fx = 0; fy = 0; return }
        let dead = 2.0                                // 度/秒：滤掉手抖
        func dz(_ v: Double) -> Double { abs(v) < dead ? 0 : v - (v > 0 ? dead : -dead) }
        var wx = -dz(yaw), wy = -dz(pitch)
        if c.invertX { wx = -wx }
        if c.invertY { wy = -wy }
        fx = fx * 0.35 + wx * 0.65
        fy = fy * 0.35 + wy * 0.65
        let speed = (fx * fx + fy * fy).squareRoot()
        let g = c.gain * min(max(0.55 + speed / 70, 0.55), 2.6)   // 慢转精确，快甩走得远
        let dx = fx * dt * g, dy = fy * dt * g
        if dx != 0 || dy != 0 { sender.addMove(dx: dx, dy: dy) }
    }

    /// 捏合检测：手指相碰会让手腕加速度出现一个很短的尖峰。只在手腕大致静止时检测，避免移动光标时误触发。
    private func detectPinch(_ m: CMDeviceMotion, rot: Double, c: AirConfig) {
        let a = m.userAcceleration
        defer { prevAccel = a }
        guard let pa = prevAccel else { return }
        let jerk = ((a.x - pa.x) * (a.x - pa.x) + (a.y - pa.y) * (a.y - pa.y) + (a.z - pa.z) * (a.z - pa.z)).squareRoot()
        let now = m.timestamp

        peak = max(peak * 0.97, jerk)
        if now - lastPeakReport > 0.25 {
            lastPeakReport = now
            let v = peak, cb = onPeak
            DispatchQueue.main.async { cb?(v) }
        }

        guard c.pinchEnabled, rot < 60, jerk > c.pinchThreshold, now - lastPinchAt > 0.12 else { return }
        lastPinchAt = now
        let cb = onPinch
        DispatchQueue.main.async { cb?() }
    }
}

private func dot(_ a: [Double], _ b: [Double]) -> Double { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
private func cross(_ a: [Double], _ b: [Double]) -> [Double] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}
private func norm(_ a: [Double]) -> Double { (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).squareRoot() }

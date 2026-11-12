import Foundation

/// 把遥控消息发给 Mac。watchOS 不允许普通 App 用 WebSocket / TCP（只有音频流 App 例外），
/// 所以每 50ms 把攒下来的移动、点击、滚动打成一包，用 HTTP POST 到 Mac 的 /batch（连接会复用）。
final class Sender {
    struct Target { var host: String; var altHost: String; var port: Int; var token: String }

    private let lock = NSLock()
    private var dx = 0.0, dy = 0.0
    private var scrollAccum = 0.0
    private var scrollActive = false
    private var lastScrollInput: TimeInterval = 0
    private var events: [[String: Any]] = []
    private var inFlight = false
    private var lastSent: TimeInterval = 0
    private var useAlt = false
    private var timer: Timer?
    private let session: URLSession

    var target: Target
    /// (是否连通, 往返毫秒, 错误说明)
    var onStatus: ((Bool, Int?, String?) -> Void)?

    init(target: Target) {
        self.target = target
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 2
        cfg.httpMaximumConnectionsPerHost = 1
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func addMove(dx: Double, dy: Double) {
        lock.lock(); self.dx += dx; self.dy += dy; lock.unlock()
    }

    func add(_ e: [String: Any]) {
        lock.lock(); events.append(e); lock.unlock()
    }

    /// 表冠滚动：自动补上「开始 / 结束」阶段，Mac 端按触控板滚动处理
    func addScroll(_ pixels: Double) {
        lock.lock()
        scrollAccum += pixels
        lastScrollInput = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if inFlight { lock.unlock(); return }
        var batch = events
        events.removeAll()
        if dx != 0 || dy != 0 {
            batch.append(["t": "move", "dx": (dx * 100).rounded() / 100, "dy": (dy * 100).rounded() / 100])
            dx = 0; dy = 0
        }
        if scrollAccum != 0 {
            if !scrollActive { batch.append(["t": "scroll", "dx": 0, "dy": 0, "p": 1, "m": 0]); scrollActive = true }
            batch.append(["t": "scroll", "dx": 0, "dy": scrollAccum, "p": 2, "m": 0])
            scrollAccum = 0
        } else if scrollActive && now - lastScrollInput > 0.15 {
            batch.append(["t": "scroll", "dx": 0, "dy": 0, "p": 4, "m": 0])
            scrollActive = false
        }
        // 没事可发时每秒发一次 ping，用来显示连接状态和延迟
        if batch.isEmpty {
            if now - lastSent < 1.0 { lock.unlock(); return }
            batch.append(["t": "ping", "id": 0])
        }
        inFlight = true
        lastSent = now
        let t = target
        let host = useAlt && !t.altHost.isEmpty ? t.altHost : t.host
        lock.unlock()

        guard let url = URL(string: "http://\(host):\(t.port)/batch"),
              let body = try? JSONSerialization.data(withJSONObject: batch) else {
            finish(ok: false, ms: nil, err: "地址不对")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(t.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let t0 = ProcessInfo.processInfo.systemUptime
        session.dataTask(with: req) { [weak self] _, resp, error in
            guard let self = self else { return }
            let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            if let http = resp as? HTTPURLResponse {
                if http.statusCode == 200 { self.finish(ok: true, ms: ms, err: nil) }
                else if http.statusCode == 401 { self.finish(ok: false, ms: nil, err: "token 不对") }
                else { self.finish(ok: false, ms: nil, err: "Mac 返回 \(http.statusCode)") }
            } else {
                // 连不上就在 IP 和 .local 名字之间切换着试
                self.lock.lock(); self.useAlt.toggle(); self.lock.unlock()
                self.finish(ok: false, ms: nil, err: error.map { _ in "连不上 Mac" } ?? "连不上 Mac")
            }
        }.resume()
    }

    private func finish(ok: Bool, ms: Int?, err: String?) {
        lock.lock(); inFlight = false; lock.unlock()
        let cb = onStatus
        DispatchQueue.main.async { cb?(ok, ms, err) }
    }
}

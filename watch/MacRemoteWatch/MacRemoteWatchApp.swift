import SwiftUI
import WatchKit

@main
struct MacRemoteWatchApp: App {
    @StateObject private var remote = Remote()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            NavigationStack { RemoteView() }
                .environmentObject(remote)
        }
        .onChange(of: phase) { _, p in
            if p == .active { remote.resume() }
            if p == .background { remote.suspend() }
        }
    }
}

/// 设置项（存在手表上）
enum Key {
    static let host = "host", altHost = "altHost", port = "port", token = "token"
    static let gain = "gain", invertX = "invertX", invertY = "invertY", autoPause = "autoPause"
    static let pinch = "pinch", pinchThreshold = "pinchThreshold"
    static let doubleTapAction = "doubleTapAction", crownInvert = "crownInvert", crownSpeed = "crownSpeed"
}

final class Remote: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    @Published var connected = false
    @Published var statusText = "连接中…"
    @Published var paused = false
    @Published var armDown = false
    @Published var peak = 0.0
    @Published var lastAction = ""

    let sender: Sender
    let engine: AirEngine
    private var runtime: WKExtendedRuntimeSession?
    private var pendingLeft: DispatchWorkItem?
    private var lastRight: TimeInterval = 0
    private var settingsTimer: Timer?

    override init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Key.host: WatchDefaults.host, Key.altHost: WatchDefaults.altHost,
            Key.port: WatchDefaults.port, Key.token: WatchDefaults.token,
            Key.gain: 14.0, Key.invertX: false, Key.invertY: false, Key.autoPause: true,
            Key.pinch: true, Key.pinchThreshold: 0.08,
            Key.doubleTapAction: "right", Key.crownInvert: false, Key.crownSpeed: 14.0,
        ])
        sender = Sender(target: .init(host: d.string(forKey: Key.host) ?? "", altHost: d.string(forKey: Key.altHost) ?? "",
                                      port: d.integer(forKey: Key.port), token: d.string(forKey: Key.token) ?? ""))
        engine = AirEngine(sender: sender)
        super.init()

        sender.onStatus = { [weak self] ok, ms, err in
            guard let self = self else { return }
            self.connected = ok
            self.statusText = ok ? "已连接 · \(ms ?? 0)ms" : (err ?? "连不上 Mac")
        }
        engine.onPinch = { [weak self] in self?.pinched() }
        engine.onPeak = { [weak self] v in self?.peak = v }
        engine.onArmDown = { [weak self] v in self?.armDown = v }
        applySettings()
        // 设置页改了参数，半秒内生效
        settingsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.applySettings() }
    }

    func applySettings() {
        let d = UserDefaults.standard
        let wrist = WKInterfaceDevice.current()
        // 左手戴、表冠在右 / 右手戴、表冠在左：表冠都朝着手掌
        let towardHand = (wrist.wristLocation == .left) == (wrist.crownOrientation == .right)
        engine.update(AirConfig(
            gain: d.double(forKey: Key.gain), invertX: d.bool(forKey: Key.invertX), invertY: d.bool(forKey: Key.invertY),
            autoPause: d.bool(forKey: Key.autoPause), pinchEnabled: d.bool(forKey: Key.pinch),
            pinchThreshold: d.double(forKey: Key.pinchThreshold), crownTowardHand: towardHand))
        sender.target = .init(host: d.string(forKey: Key.host) ?? "", altHost: d.string(forKey: Key.altHost) ?? "",
                              port: d.integer(forKey: Key.port), token: d.string(forKey: Key.token) ?? "")
    }

    func resume() {
        engine.start()
        sender.start()
        startRuntime()
    }

    func suspend() {
        engine.stop()
        sender.stop()
    }

    func togglePause() {
        paused.toggle()
        engine.setPaused(paused)
        WKInterfaceDevice.current().play(.click)
    }

    // MARK: 点击

    func click(_ button: String) {
        sender.add(["t": "click", "b": button])
        lastAction = button == "right" ? "右键" : "左键"
        WKInterfaceDevice.current().play(button == "right" ? .directionUp : .click)
    }

    /// 自己检测到的捏合：等一小会儿看有没有第二下，有就是「捏两下」
    private func pinched() {
        if let p = pendingLeft {
            p.cancel()
            pendingLeft = nil
            doubleTap()
            return
        }
        let item = DispatchWorkItem { [weak self] in
            self?.pendingLeft = nil
            self?.click("left")
        }
        pendingLeft = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    /// 系统的「双指互点两下」手势，或自己检测到的两下捏合（两者去重）
    func doubleTap() {
        pendingLeft?.cancel()
        pendingLeft = nil
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastRight < 0.8 { return }
        lastRight = now
        click(UserDefaults.standard.string(forKey: Key.doubleTapAction) == "left" ? "left" : "right")
    }

    func scroll(crownDelta: Double) {
        let d = UserDefaults.standard
        let k = d.double(forKey: Key.crownSpeed) * (d.bool(forKey: Key.crownInvert) ? -1 : 1)
        sender.addScroll(crownDelta * k)
    }

    // MARK: 后台持续运行（抬腕 / 放下手腕时不被系统挂起，最长约 1 小时）

    private func startRuntime() {
        if let r = runtime, r.state == .running || r.state == .scheduled { return }
        let r = WKExtendedRuntimeSession()
        r.delegate = self
        r.start()
        runtime = r
    }

    func extendedRuntimeSessionDidStart(_ s: WKExtendedRuntimeSession) {}
    func extendedRuntimeSessionWillExpire(_ s: WKExtendedRuntimeSession) {}
    func extendedRuntimeSession(_ s: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        DispatchQueue.main.async { if self.runtime === s { self.runtime = nil } }
    }
}

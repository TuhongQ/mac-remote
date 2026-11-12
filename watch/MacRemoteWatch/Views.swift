import SwiftUI

struct RemoteView: View {
    @EnvironmentObject var remote: Remote
    @State private var crown = 0.0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(remote.connected ? Color.green : Color.red).frame(width: 7, height: 7)
                Text(remote.statusText).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }

            Button { remote.click("left") } label: {
                Label("左键", systemImage: "cursorarrow.click").frame(maxWidth: .infinity)
            }
            .tint(.blue)

            // 系统的「双指互点两下」手势会触发这个按钮
            Button { remote.doubleTap() } label: {
                Label("右键", systemImage: "contextualmenu.and.cursorarrow").frame(maxWidth: .infinity)
            }
            .handGestureShortcut(.primaryAction)

            Button { remote.togglePause() } label: {
                Label(remote.paused ? "继续体感" : "暂停体感", systemImage: remote.paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(remote.paused ? .orange : .gray)

            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 4)
        .focusable()
        .digitalCrownRotation($crown, from: -1_000_000, through: 1_000_000, by: 0.1,
                              sensitivity: .high, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { old, new in remote.scroll(crownDelta: new - old) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
        }
        .navigationTitle("Mac 遥控")
    }

    private var hint: String {
        if remote.paused { return "已暂停：光标不跟手" }
        if remote.armDown { return "手臂垂下，光标已停" }
        return "转手腕移动 · 表冠滚动\n捏一下左键 · 捏两下右键"
    }
}

struct SettingsView: View {
    @EnvironmentObject var remote: Remote
    @AppStorage(Key.gain) private var gain = 14.0
    @AppStorage(Key.invertX) private var invertX = false
    @AppStorage(Key.invertY) private var invertY = false
    @AppStorage(Key.autoPause) private var autoPause = true
    @AppStorage(Key.pinch) private var pinch = true
    @AppStorage(Key.pinchThreshold) private var pinchThreshold = 0.08
    @AppStorage(Key.doubleTapAction) private var doubleTapAction = "right"
    @AppStorage(Key.crownInvert) private var crownInvert = false
    @AppStorage(Key.crownSpeed) private var crownSpeed = 14.0
    @AppStorage(Key.host) private var host = ""
    @AppStorage(Key.altHost) private var altHost = ""
    @AppStorage(Key.token) private var token = ""

    var body: some View {
        List {
            Section("体感") {
                VStack(alignment: .leading) {
                    Text("灵敏度 \(Int(gain))")
                    Slider(value: $gain, in: 4...40, step: 2)
                }
                Toggle("左右反转", isOn: $invertX)
                Toggle("上下反转", isOn: $invertY)
                Toggle("手臂垂下暂停", isOn: $autoPause)
            }
            Section {
                Toggle("捏一下 = 左键", isOn: $pinch)
                VStack(alignment: .leading) {
                    Text("捏合阈值 \(pinchThreshold, specifier: "%.2f")")
                    Slider(value: $pinchThreshold, in: 0.02...0.4, step: 0.01)
                    Text("刚才的冲击 \(remote.peak, specifier: "%.2f")").font(.footnote).foregroundStyle(.secondary)
                }
                Picker("捏两下", selection: $doubleTapAction) {
                    Text("右键").tag("right")
                    Text("左键").tag("left")
                }
            } header: {
                Text("捏合（实验）")
            } footer: {
                Text("手腕不动，捏一下手指看「刚才的冲击」是多少，把阈值调到比它略低。误触多就调高。")
            }
            Section("表冠滚动") {
                VStack(alignment: .leading) {
                    Text("速度 \(Int(crownSpeed))")
                    Slider(value: $crownSpeed, in: 4...40, step: 2)
                }
                Toggle("方向反转", isOn: $crownInvert)
            }
            Section("连接") {
                TextField("Mac 的 IP", text: $host)
                TextField("备用地址", text: $altHost)
                TextField("token", text: $token)
            }
        }
        .navigationTitle("设置")
    }
}

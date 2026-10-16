import SwiftUI
import AppKit

@MainActor
final class ConnectionModel: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var busy = false
    @Published var scanning = false
    @Published var message = "正在寻找局域网中的安卓手机…"
    @Published var isError = false
    @Published var pairingID = ""
    @Published var code = ""
    @Published var manualPairAddress = ""
    @Published var manualConnectAddress = ""
    @Published var showPairing = false
    @Published var showManual = false
    @Published var details = ""
    @Published var lastScan: Date?
    let adb = ADB()
    let deviceNames = DeviceNames()
    private var timer: Timer?
    private var resolvedIdentities = Set<String>()
    private var remembered: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "rememberedServices") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "rememberedServices") }
    }

    var pairingTarget: Service? { snapshot.pairing.first { $0.id == pairingID } }
    var canPair: Bool {
        code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber } &&
        (pairingTarget != nil || (showManual && adb.validEndpoint(manualPairAddress)))
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(quiet: true) }
        }
    }

    private func apply(_ state: Snapshot) {
        snapshot = state
        lastScan = Date()
        if !state.pairing.contains(where: { $0.id == pairingID }) {
            pairingID = state.pairing.count == 1 ? state.pairing[0].id : ""
        }
        // Existing online wireless transports have already been authorized by adb.
        var known = remembered
        for service in state.connecting where state.device(for: service)?.online == true { known.insert(service.name) }
        remembered = known
        for device in state.online {
            let service = state.connecting.first { $0.matches(device.serial) }
            let token = service?.name ?? device.serial
            guard resolvedIdentities.insert(token).inserted else { continue }
            Task {
                let adb = self.adb
                let serial = await Task.detached { adb.hardwareSerial(for: device.serial) }.value
                if let serial { deviceNames.learn(serial: serial, service: service, transport: device.serial) }
                else { resolvedIdentities.remove(token) }
            }
        }
    }

    func refresh(quiet: Bool = false) {
        guard !busy && !scanning else { return }
        scanning = true
        Task {
            let adb = self.adb
            let state = await Task.detached { adb.snapshot() }.value
            apply(state)
            scanning = false
            if !quiet {
                if let problem = state.problem { setMessage(problem, error: true) }
                else if !state.online.isEmpty { setMessage("已连接，可在终端或其他工具中使用。") }
                else if !state.pairing.isEmpty { showPairing = true; setMessage("发现配对中的手机，输入手机显示的六位码即可。") }
                else { setMessage("已配对请点「一键连接」；首次使用请展开下方配对入口。") }
            } else if !state.online.isEmpty && !isError {
                setMessage("已连接，可在终端或其他工具中使用。")
            } else if state.online.isEmpty && message.hasPrefix("已连接") {
                setMessage("设备已离线。请打开手机无线调试，然后一键连接。")
            }
        }
    }

    private func setMessage(_ value: String, error: Bool = false) { message = value; isError = error }

    func oneClick() {
        guard !busy && !scanning else { return }
        busy = true
        setMessage("正在寻找已配对的手机…")
        let known = remembered
        Task {
            let adb = self.adb
            let outcome = await Task.detached { () -> (Snapshot, String, Bool, String) in
                var state = adb.snapshot()
                if !state.online.isEmpty { return (state, "已连接，可在终端或其他工具中使用。", false, "设备在线，无需重复连接。") }
                var repairLog = ""
                if state.services.isEmpty || state.problem != nil {
                    let repair = adb.restart()
                    repairLog = "重新启动 ADB：\n" + repair.output + "\n"
                    if repair.ok {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        state = adb.snapshot()
                    } else { return (state, adb.friendly(repair.output), true, repairLog) }
                }
                if let problem = state.problem { return (state, problem, true, repairLog) }
                if !state.online.isEmpty { return (state, "已连接，可在终端或其他工具中使用。", false, repairLog) }
                let saved = state.connecting.filter { known.contains($0.name) }
                let targets = saved.isEmpty ? (state.connecting.count == 1 ? state.connecting : []) : saved
                if targets.isEmpty {
                    if !state.connecting.isEmpty { return (state, "发现多台手机，请在设备列表中选择要连接的手机。", false, repairLog) }
                    if !state.pairing.isEmpty { return (state, "发现配对中的手机，请在下方输入六位配对码。", false, repairLog) }
                    return (state, "未发现手机。请确认同一 Wi-Fi 并开启无线调试；也可展开手动地址连接。", true, repairLog)
                }
                var log = repairLog
                for target in targets {
                    let result = adb.connect(endpoint: target.endpoint)
                    log += target.endpoint + "\n" + result.output + "\n"
                }
                state = adb.snapshot()
                let success = targets.contains { state.device(for: $0)?.online == true }
                return (state, success ? "已连接，可在终端或其他工具中使用。" : "连接未完成。首次使用请先配对；已配对请确认无线调试仍然开启。", !success, log)
            }.value
            apply(outcome.0); setMessage(outcome.1, error: outcome.2); details = outcome.3
            if !outcome.0.pairing.isEmpty && outcome.0.online.isEmpty { showPairing = true }
            busy = false
        }
    }

    func connect(_ service: Service? = nil) {
        guard !busy && !scanning else { return }
        let endpoint = service?.endpoint ?? manualConnectAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; setMessage("正在连接手机…")
        Task {
            let adb = self.adb
            let outcome = await Task.detached { () -> (CommandResult, Snapshot) in
                let result = adb.connect(endpoint: endpoint)
                return (result, adb.snapshot())
            }.value
            apply(outcome.1)
            let verified: Bool
            if let service { verified = outcome.1.device(for: service)?.online == true }
            else { verified = outcome.1.devices.contains { $0.online && $0.serial == endpoint } }
            if verified, let service { var known = remembered; known.insert(service.name); remembered = known }
            setMessage(verified ? "已连接，可在终端或其他工具中使用。" : (outcome.0.ok ? "连接请求已发送，但设备尚未在线。请重新检测。" : adb.friendly(outcome.0.output)), error: !verified)
            details = outcome.0.output; busy = false
        }
    }

    func pair() {
        guard !busy && !scanning && canPair else { return }
        let endpoint = pairingTarget?.endpoint ?? manualPairAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentCode = code
        // Capture matching host: pairing and connection services may have different names.
        let host = adb.host(of: endpoint)
        code = ""; busy = true; setMessage("正在配对，随后自动连接…")
        Task {
            let adb = self.adb
            let outcome = await Task.detached { () -> (Snapshot, String, Bool, String) in
                let deadline = ProcessInfo.processInfo.systemUptime + 45
                func remaining() -> TimeInterval { max(0.1, deadline - ProcessInfo.processInfo.systemUptime) }
                let result = adb.pair(endpoint: endpoint, code: currentCode)
                guard result.ok && result.output.lowercased().contains("successfully paired") else {
                    return (adb.snapshot(), adb.friendly(result.output), true, result.output.replacingOccurrences(of: currentCode, with: "••••••"))
                }
                var state = Snapshot()
                var log = result.output
                for _ in 0..<3 {
                    guard remaining() > 1 else { break }
                    state = adb.snapshot(timeout: min(4, remaining()))
                    let targets = state.connecting.filter { adb.host(of: $0.endpoint) == host }
                    if targets.contains(where: { state.device(for: $0)?.online == true }) {
                        return (state, "配对成功，手机已连接。以后点击「一键连接」即可。", false, log)
                    }
                    for target in targets {
                        guard remaining() > 1 else { break }
                        log += "\n" + adb.connect(endpoint: target.endpoint, timeout: min(5, remaining())).output
                    }
                    guard remaining() > 1 else { break }
                    state = adb.snapshot(timeout: min(4, remaining()))
                    if targets.contains(where: { state.device(for: $0)?.online == true }) {
                        return (state, "配对成功，手机已连接。以后点击「一键连接」即可。", false, log)
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                return (state, "配对已完成，但尚未连接。请关闭手机的配对码弹窗，保持无线调试开启，再点「一键连接」。", true, log)
            }.value
            apply(outcome.0); setMessage(outcome.1, error: outcome.2); details = outcome.3
            busy = false
        }
    }

    func repair() {
        guard !busy && !scanning else { return }
        busy = true; setMessage("正在重新启动 ADB…")
        Task {
            let adb = self.adb
            let result = await Task.detached { adb.restart() }.value
            details = result.output
            busy = false
            if result.ok { refresh() }
            else { setMessage(adb.friendly(result.output), error: true) }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ConnectionModel()
    @State private var showDetails = false
    @FocusState private var codeFocused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 32, weight: .light)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DroidLink").font(.system(size: 25, weight: .semibold))
                        Text("安卓无线连接 · 首次输配对码，以后点一下。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: model.isError ? "exclamationmark.circle.fill" : (model.snapshot.online.isEmpty ? "wifi" : "checkmark.circle.fill"))
                            .foregroundStyle(model.isError ? Color.orange : (model.snapshot.online.isEmpty ? Color.secondary : Color.green))
                        Text(model.snapshot.online.isEmpty ? "等待连接" : "\(model.snapshot.online.count) 台手机已连接")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        if model.busy || model.scanning { ProgressView().controlSize(.small).accessibilityLabel("正在处理") }
                    }
                    Text(model.message).foregroundStyle(model.isError ? .primary : .secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button(action: model.oneClick) { Label("一键连接", systemImage: "bolt.fill").frame(minWidth: 108) }
                            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                        Button("重新检测") { model.refresh() }.controlSize(.large)
                        Spacer()
                    }.disabled(model.busy || model.scanning)
                }

                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("附近的手机").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        if let date = model.lastScan {
                            Text("\(date.formatted(date: .omitted, time: .shortened)) 更新").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.snapshot.connecting.isEmpty && model.snapshot.online.isEmpty {
                        Text("尚未发现可连接的手机。手机和 Mac 需要连在同一个 Wi-Fi，且手机已开启无线调试。")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.snapshot.connecting) { service in
                        let device = model.snapshot.device(for: service)
                        DeviceRowView(service: service, device: device, names: model.deviceNames, busy: model.busy || model.scanning) { model.connect(service) }
                    }
                    ForEach(model.snapshot.online.filter { device in !model.snapshot.connecting.contains { $0.matches(device.serial) } }) { device in
                        DeviceRowView(service: nil, device: device, names: model.deviceNames, busy: model.busy || model.scanning) {}
                    }
                    DeviceNameErrorView(names: model.deviceNames)
                }

                Divider()
                DisclosureGroup(isExpanded: $model.showPairing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("在手机上打开「无线调试 → 使用配对码配对设备」，这里会自动发现手机。保持该窗口打开。")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if model.snapshot.pairing.isEmpty {
                            Label("等待手机显示配对码… 每 4 秒自动检测", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Picker("配对手机", selection: $model.pairingID) {
                                if model.snapshot.pairing.count > 1 { Text("选择一台手机").tag("") }
                                ForEach(model.snapshot.pairing) { service in Text(service.endpoint + " · " + service.label).tag(service.id) }
                            }
                        }
                        HStack(spacing: 12) {
                            SecureField("手机上的六位配对码", text: $model.code)
                                .textFieldStyle(.roundedBorder).focused($codeFocused)
                                .onChange(of: model.code) { value in
                                    model.code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                                }
                                .onSubmit { if model.canPair { model.pair() } }
                                .accessibilityLabel("六位配对码")
                            Button("配对并连接") { model.pair() }
                                .disabled(!model.canPair || model.busy || model.scanning)
                        }
                        Text("配对码仅在本次操作中使用，不会保存。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                } label: { Text("首次使用 / 重新配对").font(.system(size: 15, weight: .semibold)) }

                DisclosureGroup(isExpanded: $model.showManual) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("只有自动发现失败时才需要填。配对端口和连接端口不同，请看手机对应页面。")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        TextField("配对码弹窗中的 IP:端口", text: $model.manualPairAddress).textFieldStyle(.roundedBorder)
                        Text("填写后，在上方输入配对码并点「配对并连接」。").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("无线调试主页中的 IP:端口", text: $model.manualConnectAddress).textFieldStyle(.roundedBorder)
                            Button("连接地址") { model.connect() }.disabled(model.busy || model.scanning || !model.adb.validEndpoint(model.manualConnectAddress))
                        }
                    }.padding(.top, 12)
                } label: { Text("手动地址连接").foregroundStyle(.secondary) }

                HStack {
                    Button("修复 ADB") { model.repair() }.disabled(model.busy || model.scanning)
                        .help("重新启动本机 ADB 服务，再检测设备。其他 ADB 调试会短暂断开。")
                    Button("操作详情") { showDetails.toggle() }
                    Spacer()
                    Text("Android 11+ · 同一 Wi-Fi").font(.caption).foregroundStyle(.secondary)
                }
                if showDetails {
                    Text(model.details.isEmpty ? "尚无操作记录。" : model.details)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(28)
        }
        .frame(minWidth: 600, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.start() }
        .onChange(of: model.showPairing) { value in if value { codeFocused = true } }
    }
}

struct DeviceNameErrorView: View {
    @ObservedObject var names: DeviceNames
    var body: some View {
        if let error = names.saveError {
            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DeviceRowView: View {
    let service: Service?
    let device: Device?
    @ObservedObject var names: DeviceNames
    let busy: Bool
    let onConnect: () -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool
    var key: String {
        if let service { return names.key(for: service) }
        if let device { return names.key(for: device) }
        return "unavailable"
    }
    private var fallbackName: String { device?.model ?? service?.label ?? "安卓设备" }
    private var remark: String? { names.name(for: key) }
    private var displayName: String { remark ?? fallbackName }
    private var subtitle: String {
        let endpoint = service?.endpoint ?? device?.serial ?? ""
        return remark == nil ? endpoint : fallbackName + " · " + endpoint
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            rowHeader
            if editing { nameEditor }
        }.padding(.vertical, 6)
    }
    private var rowHeader: some View {
        HStack(spacing: 12) {
                Image(systemName: "smartphone").font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .fontWeight(.medium).lineLimit(2).textSelection(.enabled)
                    Text(subtitle)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button(remark == nil ? "备注" : "改名") {
                    draft = remark ?? ""; editing.toggle(); nameFocused = editing
                }.buttonStyle(.borderless).help("为这台手机设置永久保留的备注名")
                if device?.online == true {
                    Label("已连接", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                } else if service != nil {
                    Button("连接", action: onConnect).disabled(busy)
                }
        }
    }
    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("给这台手机起个名字", text: $draft).textFieldStyle(.roundedBorder)
                        .focused($nameFocused).onSubmit(saveName)
                        .onChange(of: draft) { value in if value.count > 80 { draft = String(value.prefix(80)) } }
                    Button("保存", action: saveName)
                    Button("取消") { editing = false }
                }
                Text("留空并保存可清除备注。更换 IP 或端口后仍会保留。")
                    .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func saveName() {
        if names.setName(draft, for: key) { editing = false }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DroidLink"
        window.contentView = NSHostingView(rootView: ContentView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil); return true
    }
}

@main
struct Entry {
    static func main() {
        if CommandLine.arguments.contains("--inspect") {
            let adb = ADB(), state = adb.snapshot()
            print("ADB: \(adb.path ?? "missing")")
            for service in state.services { print("\(service.isPairing ? "PAIR" : "CONNECT") \(service.name) \(service.endpoint)") }
            for device in state.devices { print("DEVICE \(device.model) \(device.state) \(device.serial)") }
            if let problem = state.problem { fputs(problem + "\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 DroidLink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item)
        // Standard edit actions enable paste, copy and select-all in code/address fields.
        let editItem = NSMenuItem(), edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem); app.mainMenu = menu
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

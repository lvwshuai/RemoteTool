import SwiftUI

/// 设备列表（未连接时的首页）。对应 Android `NativeApp.kt` 里的 `DeviceScreen`：
/// 卡片式设备列表 + 添加设备 + 设备管理（地址增删 / 改名 / 删除）+ 通道选择。
struct DevicesScreen: View {
    @EnvironmentObject private var model: NativeModel

    @State private var addRequest: AddDeviceRequest?
    @State private var confirm: ConfirmRequest?
    @State private var rename: InputRequest?
    @State private var manageDevice: Device?

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("优先连接上次通道，不可达时尝试其他地址；可在设备内手动切换。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                ForEach(model.devices) { device in
                    deviceCard(device)
                }

                Section {
                    Button {
                        addRequest = AddDeviceRequest(device: nil)
                    } label: {
                        Label("添加设备", systemImage: "plus")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我的设备")
            .sheet(item: $addRequest) { request in
                AddDeviceSheet(request: request, model: model) { addRequest = nil }
            }
            .sheet(item: $manageDevice) { device in
                DeviceManagerSheet(device: device, model: model) { manageDevice = nil }
            }
            .confirmAlert($confirm)
            .inputSheet($rename)
            .sheet(isPresented: Binding(get: { model.channelDevice != nil },
                                        set: { if !$0 { model.closeChannels() } })) {
                ChannelSheet(model: model)
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func deviceCard(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "desktopcomputer")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.system(size: 17, weight: .semibold))
                    if model.session?.device.id == device.id {
                        Text("当前连接")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                    }
                }
                Spacer()
                Button {
                    manageDevice = device
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
            }
            Text("\(device.endpoints.count) 个地址 · \(String(device.id.prefix(8)))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button {
                model.connect(device)
            } label: {
                Text("连接设备").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(device.endpoints.isEmpty)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 添加设备 / 地址

struct AddDeviceRequest: Identifiable {
    let id = UUID()
    let device: Device?
}

private struct AddDeviceSheet: View {
    let request: AddDeviceRequest
    let model: NativeModel
    let onClose: () -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        NavigationView {
            Form {
                if request.device == nil {
                    Section(header: Text("设备名称")) {
                        TextField("例如：工作台式机", text: $name)
                    }
                }
                Section(header: Text("地址")) {
                    TextField("http:// 或 https:// 地址", text: $url)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                }
                if busy {
                    Section { ProgressView() }
                }
                Section {
                    Text("保存前会先请求 /api/device/identity 校验端点身份；若该地址属于另一台电脑会被拒绝。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(request.device == nil ? "添加设备" : "添加地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onClose() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("验证并保存") { submit() }
                        .disabled(busy || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func submit() {
        busy = true
        errorText = nil
        let displayName = name
        var typed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只填了 `192.168.1.10:5104` 时，按「允许明文」补上 scheme，省一次输入。
        if !typed.lowercased().hasPrefix("http"), DebugOverrides.allowCleartext {
            typed = "http://" + typed
        }
        let raw = typed
        let expected = request.device?.id
        Task {
            do {
                try await model.add(name: displayName, raw: raw, expected: expected)
                onClose()
            } catch {
                errorText = connectionFailureMessage(error)
            }
            busy = false
        }
    }
}

// MARK: - 设备管理

private struct DeviceManagerSheet: View {
    @State var device: Device
    let model: NativeModel
    let onClose: () -> Void

    @State private var addRequest: AddDeviceRequest?
    @State private var confirm: ConfirmRequest?
    @State private var rename: InputRequest?

    init(device: Device, model: NativeModel, onClose: @escaping () -> Void) {
        _device = State(initialValue: device)
        self.model = model
        self.onClose = onClose
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text(device.name)) {
                    if device.endpoints.isEmpty {
                        Text("暂无地址").foregroundColor(.secondary)
                    }
                    ForEach(device.endpoints, id: \.self) { url in
                        HStack {
                            Text(url)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button {
                                model.removeEndpoint(device, url: url)
                                sync()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                        }
                    }
                }

                Section {
                    Button("添加地址") { addRequest = AddDeviceRequest(device: device) }
                    Button("修改名称") {
                        rename = InputRequest(title: "修改名称", label: "设备名称",
                                              initial: device.name) { value in
                            model.rename(device, to: value)
                            sync()
                        }
                    }
                    Button("删除设备", role: .destructive) {
                        confirm = ConfirmRequest(title: "删除设备",
                                                 message: "仅移除 App 中的 \(device.name) 配置。",
                                                 destructive: true) {
                            model.forget(device)
                            onClose()
                        }
                    }
                }

                Section {
                    Text("指纹 \(device.id)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("管理设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onClose() }
                }
            }
            .sheet(item: $addRequest) { request in
                AddDeviceSheet(request: request, model: model) {
                    addRequest = nil
                    sync()
                }
            }
            .confirmAlert($confirm)
            .inputSheet($rename)
        }
        .navigationViewStyle(.stack)
    }

    /// 地址被增删后刷新本地快照，否则列表不会跟着变。
    private func sync() {
        if let latest = model.devices.first(where: { $0.id == device.id }) {
            device = latest
        } else {
            onClose()
        }
    }
}

// MARK: - 通道选择

/// 对应 Android `ChannelDialog.kt`：并行探测所有地址，逐个显示结果，点可用的那一条切换。
private struct ChannelSheet: View {
    @ObservedObject var model: NativeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if let device = model.channelDevice {
                    Section(header: Text(device.name)) {
                        ForEach(model.channelChecks) { check in
                            row(check)
                        }
                    }
                    Section {
                        Text("选中通道会重新验证端点身份后再携带 token 连接，无需重新输入密码。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("连接通道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { model.closeChannels(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.refreshChannels()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.checkingChannels)
                }
            }
            .onAppear { model.refreshChannels() }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func row(_ check: ChannelCheck) -> some View {
        Button {
            model.selectChannel(check.url)
            if model.session != nil, !model.loginNeeded { dismiss() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(check.url)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
                switch check.state {
                case .checking:
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("检测中…").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                case .reachable(let ms):
                    Text("可用 · \(ms) ms")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                case .failed(let reason):
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }
        }
        .disabled(!check.isReachable || model.checkingChannels || model.connecting)
    }
}

import Foundation

/// 应用级状态：设备列表、通道测速、连接与认证恢复。
/// 对应 Android `nativeui/NativeData.kt` 里的 `NativeModel`（`AndroidViewModel`）。
///
/// 并发模型说明：Android 用 `connectionEpoch` + `Job.cancel()` 保证「只有最后一次连接请求能落地」。
/// iOS 这边用同样的 epoch 计数 + `Task` 取消，语义完全一致，避免连点设备时旧请求覆盖新会话。
@MainActor
final class NativeModel: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published private(set) var session: Session?
    @Published private(set) var browsingDevices = false
    @Published private(set) var connecting = false
    @Published private(set) var channelDevice: Device?
    @Published private(set) var channelChecks: [ChannelCheck] = []
    @Published private(set) var checkingChannels = false
    @Published var loginNeeded = false
    @Published var message: String?

    private let store = DeviceStore()
    private let credentials = DeviceCredentialStore()
    private var authSessions: [String: DeviceAuthSession] = [:]
    private var connectTask: Task<Void, Never>?
    private var connectionEpoch = 0
    private var connectingDeviceId: String?

    init() {
        devices = store.loadDevices()
        restoreLastDevice()
    }

    // MARK: - 启动恢复

    /// 对应 Android `init`：优先用上次设备，其次用「唯一且已有通道记录」的设备。
    private func restoreLastDevice() {
        if let lastId = store.lastDeviceId, let device = devices.first(where: { $0.id == lastId }) {
            connect(device)
            return
        }
        if devices.count == 1, let only = devices.first, store.hasChannel(only.id) {
            connect(only)
            return
        }
    }

    // MARK: - 设备浏览

    /// 业务页面统一的上报入口（等价 Android `NativeApp` 里传给各页面的 `error` lambda）：
    /// 登录过期要顺带把界面推回登录页，否则用户会一直看到「登录已过期」却无处输入密码。
    func report(_ message: String) {
        if message.contains("登录已过期") { loginNeeded = true }
        self.message = message
    }

    /// 业务页面读取失败的统一包装：401 时把会话推到登录页。
    func handleReadFailure(_ error: Error) {
        report(connectionFailureMessage(error))
    }

    func showDevices() { browsingDevices = true }
    func returnToDevice() { browsingDevices = false }

    func add(name: String, raw: String, expected: String?) async throws {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme, ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty else {
            throw NSError(domain: "RemoteTool", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "请输入完整的 http:// 或 https:// 根地址"])
        }
        let url = trimmed
        let (id, _) = try await probe(url)
        if let expected, id != expected {
            throw NSError(domain: "RemoteTool", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "此地址属于另一台电脑，不能加入当前设备"])
        }

        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = devices.firstIndex(where: { $0.id == id }) {
            if !devices[index].endpoints.contains(url) {
                devices[index].endpoints.append(url)
                if devices[index].endpoints.count > DeviceStore.maxEndpointsPerDevice {
                    devices[index].endpoints.removeFirst(devices[index].endpoints.count - DeviceStore.maxEndpointsPerDevice)
                }
            }
        } else {
            devices.append(Device(id: id, name: displayName.isEmpty ? "新设备" : displayName, endpoints: [url]))
        }
        persist()
    }

    func rename(_ device: Device, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].name = trimmed
        persist()
    }

    func removeEndpoint(_ device: Device, url: String) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].endpoints.removeAll { $0 == url }
        persist()
    }

    func forget(_ device: Device) {
        credentials.remove(device.id)
        authSessions[device.id]?.token = nil
        authSessions.removeValue(forKey: device.id)
        for endpoint in device.endpoints {
            NativeApi(base: endpoint, authentication: nil).clearToken()
        }
        devices.removeAll { $0.id == device.id }
        store.forget(device.id)
        persist()

        if session?.device.id == device.id || connectingDeviceId == device.id {
            disconnect()
        }
    }

    private func persist() { store.saveDevices(devices) }

    func savedUsername(_ deviceId: String) -> String { credentials.storedUsername(deviceId) }

    // MARK: - 连接

    func preferredChannel(_ device: Device) -> String? {
        if let session, session.device.id == device.id { return session.api.base }
        return store.preferredChannel(device.id)
    }

    func disconnect() {
        connectionEpoch += 1
        connectTask?.cancel()
        connectTask = nil
        connecting = false
        connectingDeviceId = nil
        session = nil
        browsingDevices = false
        loginNeeded = false
        channelDevice = nil
        channelChecks = []
        checkingChannels = false
    }

    func connect(_ device: Device) {
        let current = devices.first { $0.id == device.id } ?? device
        let url = preferredChannel(current).flatMap { current.endpoints.contains($0) ? $0 : nil }
            ?? current.endpoints.first
        guard let url else { return }
        channelDevice = nil
        checkingChannels = false
        channelChecks = []
        startConnection(device: current, url: url, allowFallback: true)
    }

    func openChannels(_ device: Device) {
        channelDevice = devices.first { $0.id == device.id } ?? device
        refreshChannels()
    }

    func closeChannels() {
        connectionEpoch += 1
        connectTask?.cancel()
        connectTask = nil
        connecting = false
        connectingDeviceId = nil
        checkingChannels = false
        channelDevice = nil
    }

    /// 并行探测该设备的全部地址，逐个更新结果（对应 Android `refreshChannels`）。
    func refreshChannels() {
        guard let device = channelDevice else { return }
        let epoch = bumpEpoch()
        checkingChannels = true
        channelChecks = device.endpoints.map { ChannelCheck(url: $0, state: .checking) }

        connectTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: ChannelCheck.self) { group in
                for url in device.endpoints {
                    group.addTask { [weak self] in
                        guard let self else { return ChannelCheck(url: url, state: .failed(reason: "已取消")) }
                        do {
                            let (id, endpoint) = try await self.probe(url)
                            if id != device.id {
                                return ChannelCheck(url: url, state: .failed(reason: "设备标识不匹配，属于另一台电脑"))
                            }
                            return ChannelCheck(url: url, state: .reachable(ms: endpoint.ms))
                        } catch is CancellationError {
                            return ChannelCheck(url: url, state: .failed(reason: "已取消"))
                        } catch {
                            return ChannelCheck(url: url, state: .failed(reason: channelErrorText(error)))
                        }
                    }
                }
                for await result in group {
                    guard epoch == self.connectionEpoch else { continue }
                    self.channelChecks = self.channelChecks.map { $0.url == result.url ? result : $0 }
                }
            }
            if epoch == self.connectionEpoch { self.checkingChannels = false }
        }
    }

    func selectChannel(_ url: String) {
        guard let device = channelDevice else { return }
        guard !checkingChannels, !connecting,
              channelChecks.contains(where: { $0.url == url && $0.isReachable }) else { return }

        if session?.device.id == device.id, session?.api.base == url, !loginNeeded {
            browsingDevices = false
            closeChannels()
            return
        }
        startConnection(device: device, url: url, allowFallback: false)
    }

    @discardableResult
    private func bumpEpoch() -> Int {
        connectionEpoch += 1
        return connectionEpoch
    }

    private func startConnection(device: Device, url: String, allowFallback: Bool) {
        let epoch = bumpEpoch()
        connectTask?.cancel()
        connecting = true
        connectingDeviceId = device.id

        connectTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if epoch == self.connectionEpoch {
                    self.connecting = false
                    self.connectingDeviceId = nil
                }
            }
            do {
                // 分享该设备的 token 之前，必须再确认一次端点身份。
                let candidates = allowFallback
                    ? DeviceAddressSelection.candidates(device.endpoints, preferred: url)
                    : [url]
                let (id, selected) = try await DeviceAddressSelection.selectVerified(
                    candidates, expectedIdentity: device.id) { candidate in
                        try await self.probe(candidate)
                    }
                guard id == device.id else {
                    throw NSError(domain: "RemoteTool", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "设备标识不匹配，属于另一台电脑"])
                }

                let reachable = self.channelChecks.filter { $0.isReachable }.compactMap { check -> Endpoint? in
                    guard let ms = check.ms else { return nil }
                    return Endpoint(url: check.url, ms: ms)
                }
                try Task.checkCancellation()
                guard epoch == self.connectionEpoch else { return }

                let verificationAuth = DeviceAuthSession()
                let verificationApi = NativeApi(base: selected.url, authentication: verificationAuth)

                let recovered = try await DeviceAuthentication.recover(
                    deviceId: device.id,
                    observedId: id,
                    read: { self.credentials.read(device.id) },
                    legacyTokens: {
                        LegacySessionStore.tokens(for: [selected.url] + device.endpoints)
                    },
                    validate: { token in
                        verificationAuth.token = token
                        do {
                            _ = try await verificationApi.json("/api/auth/me")
                            return true
                        } catch {
                            return false
                        }
                    },
                    signIn: { login in
                        do { return try await verificationApi.login(username: login.username, password: login.password) }
                        catch { return nil }
                    },
                    save: { login in try self.credentials.save(device.id, login) }
                )

                try Task.checkCancellation()
                guard epoch == self.connectionEpoch else { return }

                let authentication = self.authSessions[device.id] ?? {
                    let created = DeviceAuthSession()
                    self.authSessions[device.id] = created
                    return created
                }()
                let api = NativeApi(base: selected.url, authentication: authentication)
                if let recovered {
                    api.installToken(recovered.token)
                } else {
                    authentication.token = nil
                }

                guard epoch == self.connectionEpoch else { return }
                self.loginNeeded = recovered == nil
                let ordered = reachable.filter { $0.url != selected.url } + [Endpoint(url: selected.url, ms: 0)]
                self.session = Session(device: device, channels: ordered, api: api)
                self.store.setPreferredChannel(device.id, url: selected.url)
                self.browsingDevices = false
                self.channelDevice = nil
                self.channelChecks = []
            } catch is CancellationError {
                return
            } catch {
                guard epoch == self.connectionEpoch else { return }
                let text = connectionFailureMessage(error)
                self.message = text
                if !self.channelChecks.isEmpty {
                    self.channelChecks = self.channelChecks.map {
                        $0.url == url ? ChannelCheck(url: url, state: .failed(reason: channelErrorText(error))) : $0
                    }
                }
            }
        }
    }

    // MARK: - 登录

    func login(_ target: Session, username: String, password: String) async throws {
        let (identity, _) = try await probe(target.api.base)
        if identity != target.device.id {
            throw NSError(domain: "RemoteTool", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "设备标识不匹配，属于另一台电脑"])
        }
        let token = try await target.api.login(username: username, password: password)
        try credentials.save(target.device.id, DeviceLogin(username: username, password: password, token: token))
        if session?.device.id == target.device.id { loginNeeded = false }
    }

    // MARK: - 端点探测

    /// `/api/device/identity` 是唯一匿名接口，用于在发送凭据前确认端点身份与延时。
    func probe(_ url: String) async throws -> (String, Endpoint) {
        let started = DispatchTime.now()
        let data = try await NativeApi(base: url, probing: true).json("/api/device/identity")
        let id = data.str("id")
        guard id.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw NSError(domain: "RemoteTool", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "设备标识格式不正确"])
        }
        #if DEBUG
        // 服务端 `DeviceController` 目前返回 `protocolVersion = 1`。
        // Android 客户端不校验它，正式版也保持一致（静默继续）；调试版明确提示，
        // 便于在真机上确认「是不是打到了旧服务端」。
        if data.int("protocolVersion", -1) < 1 {
            message = "服务端未声明 protocolVersion，可能为旧版本（客户端按 v1 协议工作）"
        }
        #endif
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        return (id, Endpoint(url: url, ms: Int(elapsed.rounded())))
    }
}

/// 兼容旧版本：从系统 cookie 存储里回收各端点上遗留的 `access_token`。
///
/// Android 用的是 `CookieManager.getCookie(endpoint)`。iOS 侧我们把 token 显式写进
/// `HTTPCookieStorage`（见 `NativeApi.installToken`），所以这里能读回同样的值，
/// 保证从旧会话（甚至旧 APK 时代）升上来时不必重新输密码。
enum LegacySessionStore {
    static func tokens(for endpoints: [String]) -> [String] {
        var result: [String] = []
        for endpoint in endpoints {
            guard let url = URL(string: endpoint),
                  let cookies = HTTPCookieStorage.shared.cookies(for: url) else { continue }
            for cookie in cookies where cookie.name == "access_token" && !cookie.value.isEmpty {
                result.append(cookie.value)
            }
        }
        return result
    }
}

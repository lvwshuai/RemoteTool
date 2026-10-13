import Foundation

/// 设备列表与通道选择的本地持久化。
///
/// 对应 Android 的三处 `SharedPreferences`：
/// - `MainActivity` → `devices` / `channel_<id>` / `last_device`（旧设备配置，保持同一套 JSON 结构）
///
/// 这里用 `UserDefaults`：内容不含凭据，只有设备指纹、显示名与地址列表。
/// 单个设备的地址上限沿用 Android 的 8 个，避免用户无限堆积死地址。
final class DeviceStore {
    private enum Key {
        static let devices = "devices"
        static let lastDevice = "last_device"
        static func channel(_ id: String) -> String { "channel_\(id)" }
    }

    static let maxEndpointsPerDevice = 8

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadDevices() -> [Device] {
        guard let text = defaults.string(forKey: Key.devices),
              let array = JSONCoding.parse(text) as? [Any] else { return [] }
        return array.objects().compactMap { entry in
            let id = entry.str("id")
            guard !id.isEmpty else { return nil }
            let name = entry.optStr("name") ?? "电脑"
            let endpoints = entry.array("endpoints").strings()
            return Device(id: id, name: name, endpoints: endpoints)
        }
    }

    func saveDevices(_ devices: [Device]) {
        let payload: [Any] = devices.map { device in
            jsonObject(("id", device.id), ("name", device.name), ("endpoints", device.endpoints))
        }
        guard let text = JSONCoding.string(payload) else { return }
        defaults.set(text, forKey: Key.devices)
    }

    var lastDeviceId: String? {
        get { defaults.string(forKey: Key.lastDevice) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.lastDevice) }
            else { defaults.removeObject(forKey: Key.lastDevice) }
        }
    }

    func preferredChannel(_ deviceId: String) -> String? {
        defaults.string(forKey: Key.channel(deviceId))
    }

    func setPreferredChannel(_ deviceId: String, url: String) {
        defaults.set(url, forKey: Key.channel(deviceId))
        defaults.set(deviceId, forKey: Key.lastDevice)
    }

    func hasChannel(_ deviceId: String) -> Bool {
        defaults.object(forKey: Key.channel(deviceId)) != nil
    }

    /// 忘记设备：清掉通道记录；凭据由 `DeviceCredentialStore` 单独清。
    func forget(_ deviceId: String) {
        defaults.removeObject(forKey: Key.channel(deviceId))
        if defaults.string(forKey: Key.lastDevice) == deviceId {
            defaults.removeObject(forKey: Key.lastDevice)
        }
    }
}

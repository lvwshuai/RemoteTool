import Foundation

/// 按设备保存登录凭据。对应 Android `DeviceCredentialStore`：
/// 明文（用户名/密码/token）用本机密钥加密后落盘，内存里再做一层缓存。
///
/// Android 把密文放在私有 `SharedPreferences`，iOS 放在 Keychain 的自定义条目里
/// （密文本身已被 AES-GCM 保护，放进 Keychain 只是再多一层，避免被 iTunes 备份带走）。
final class DeviceCredentialStore {
    private let lock = NSLock()
    private var cache: [String: DeviceLogin?] = [:]
    private var records: [String: String]

    init() {
        records = DeviceCredentialStore.loadRecords()
    }

    func read(_ deviceId: String) -> DeviceLogin? {
        lock.lock()
        if let cached = cache[deviceId] { lock.unlock(); return cached }
        lock.unlock()

        let login: DeviceLogin?
        if let encrypted = records[deviceId],
           let key = try? DeviceCipher.loadOrCreateKey(),
           let plain = try? DeviceCipher.decrypt(deviceId: deviceId, payload: encrypted, key: key),
           let object = JSONCoding.parse(plain) as? JSONDict {
            login = DeviceLogin(username: object.str("username"),
                                password: object.str("password"),
                                token: object.str("token"))
        } else {
            login = nil
        }

        lock.lock()
        cache[deviceId] = login
        lock.unlock()
        return login
    }

    func save(_ deviceId: String, _ login: DeviceLogin) throws {
        let plain = jsonObject(("username", login.username), ("password", login.password), ("token", login.token))
        guard let text = JSONCoding.string(plain) else {
            throw NSError(domain: "RemoteTool", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法序列化登录凭据"])
        }
        let key = try DeviceCipher.loadOrCreateKey()
        let encrypted = try DeviceCipher.encrypt(deviceId: deviceId, plain: text, key: key)

        lock.lock()
        records[deviceId] = encrypted
        cache[deviceId] = login
        let snapshot = records
        lock.unlock()

        try DeviceCredentialStore.persist(snapshot)
    }

    func remove(_ deviceId: String) {
        lock.lock()
        records.removeValue(forKey: deviceId)
        cache.removeValue(forKey: deviceId)
        let snapshot = records
        lock.unlock()
        try? DeviceCredentialStore.persist(snapshot)
    }

    func storedUsername(_ deviceId: String) -> String {
        read(deviceId)?.username ?? ""
    }

    // MARK: - 持久化

    private static func loadRecords() -> [String: String] {
        guard let data = DeviceCipher.loadData(account: DeviceCipher.keychainDeviceStoreAccount),
              let object = JSONCoding.parse(data) as? JSONDict else { return [:] }
        return object.compactMapValues { $0 as? String }
    }

    private static func persist(_ records: [String: String]) throws {
        guard let data = JSONCoding.data(records) else { return }
        try DeviceCipher.store(keyData: data, account: DeviceCipher.keychainDeviceStoreAccount)
    }
}

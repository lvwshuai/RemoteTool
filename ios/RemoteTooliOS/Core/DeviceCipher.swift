import CryptoKit
import Foundation
import Security

/// 凭据加解密。对应 Android `DeviceCredentialCipher`（AES/GCM/NoPadding）与
/// `DeviceCredentialStore` 里 Android Keystore 的不可导出密钥。
///
/// iOS 等价物：CryptoKit `AES.GCM` + Keychain 里的 AES-256 随机密钥（本机专用、不随备份迁移）。
/// 密文布局与 Android 完全一致：`base64(iv) + "." + base64(ciphertext || tag)`，
/// AAD 为设备指纹 —— 这样同一个设备保存的记录在两端结构相同，便于排查。
enum DeviceCipher {
    private static let keychainService = "com.chuckiehelper.mobile.credentials"
    private static let keychainAccount = "ChuckieHelper.DeviceCredentials.v1"
    static let keychainDeviceStoreAccount = "ChuckieHelper.DeviceCredentialRecords.v1"

    enum CipherError: LocalizedError {
        case malformedPayload

        var errorDescription: String? { "凭据数据已损坏，请重新登录" }
    }

    // MARK: - 加解密

    static func encrypt(deviceId: String, plain: String, key: SymmetricKey) throws -> String {
        let aad = Data(deviceId.utf8)
        let sealed = try AES.GCM.seal(Data(plain.utf8), using: key, authenticating: aad)
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        let body = sealed.ciphertext + sealed.tag
        return nonce.base64EncodedString() + "." + body.base64EncodedString()
    }

    static func decrypt(deviceId: String, payload: String, key: SymmetricKey) throws -> String {
        let parts = payload.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let nonceData = Data(base64Encoded: String(parts[0])),
              let body = Data(base64Encoded: String(parts[1])) else {
            throw CipherError.malformedPayload
        }
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let tagLength = 16
        guard body.count > tagLength else { throw CipherError.malformedPayload }
        let ciphertext = body.prefix(body.count - tagLength)
        let tag = body.suffix(tagLength)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let opened = try AES.GCM.open(box, using: key, authenticating: Data(deviceId.utf8))
        guard let text = String(data: opened, encoding: .utf8) else { throw CipherError.malformedPayload }
        return text
    }

    // MARK: - 密钥（Keychain）

    /// 取本机密钥；不存在则生成 256 位随机密钥并写入 Keychain。
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 保证密钥不随 iCloud 钥匙串或 iTunes 备份离开本机。
    static func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = loadKeyData() { return SymmetricKey(data: existing) }
        let generated = SymmetricKey(size: .bits256)
        let raw = generated.withUnsafeBytes { Data($0) }
        try store(keyData: raw, account: keychainAccount)
        return generated
    }

    static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func loadKeyData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// 通用 Keychain 写入（凭据记录也用同一套，避免凭据落到可被备份读出的位置）。
    static func store(keyData data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus),
                              userInfo: [NSLocalizedDescriptionKey: "无法写入本机钥匙串（\(addStatus)）"])
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法更新本机钥匙串（\(status)）"])
        }
    }

    static func loadData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func removeData(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

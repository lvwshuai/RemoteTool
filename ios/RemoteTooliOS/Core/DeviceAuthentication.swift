import Foundation

/// 设备身份校验 + 凭据恢复。逐行对应 Android `DeviceAuthentication.recover`。
///
/// 关键约束（与 Android 一致）：**在端点自证身份之前，不读取也不发送任何凭据。**
/// 顺序为：已存 token → 用已存账号密码换新 token → 旧会话遗留 token。
enum DeviceAuthentication {
    static func recover(deviceId: String,
                        observedId: String,
                        read: () -> DeviceLogin?,
                        legacyTokens: () -> [String],
                        validate: (String) async -> Bool,
                        signIn: (DeviceLogin) async -> String?,
                        save: (DeviceLogin) throws -> Void) async throws -> DeviceLogin? {
        guard observedId == deviceId else {
            throw NSError(domain: "RemoteTool", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "设备标识不匹配，属于另一台电脑"])
        }

        let saved = read()

        if let saved, !saved.token.isEmpty, await validate(saved.token) {
            return saved
        }

        if let saved, !saved.username.isEmpty, !saved.password.isEmpty {
            if let token = await signIn(saved), !token.isEmpty {
                let refreshed = saved.withToken(token)
                try? save(refreshed)
                return refreshed
            }
        }

        var seen = Set<String>()
        for token in legacyTokens() where !token.isEmpty && token != saved?.token {
            guard seen.insert(token).inserted else { continue }
            if await validate(token) {
                let base = saved ?? DeviceLogin(username: "", password: "", token: "")
                let refreshed = base.withToken(token)
                try? save(refreshed)
                return refreshed
            }
        }

        return nil
    }
}

/// 候选地址排序与逐个校验。对应 Android `deviceAddressCandidates` / `selectVerifiedDeviceAddress`。
enum DeviceAddressSelection {
    /// 首选地址排在最前，其余按用户添加顺序，去重。
    static func candidates(_ addresses: [String], preferred: String?) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        if let preferred, addresses.contains(preferred) {
            result.append(preferred)
            seen.insert(preferred)
        }
        for address in addresses where seen.insert(address).inserted {
            result.append(address)
        }
        return result
    }

    /// 依次探测每个地址，返回第一个身份匹配的结果。
    /// 全部失败时：只有一个候选就抛原始错误，多个则抛汇总错误（等价 Android 行为，便于界面区分）。
    static func selectVerified<T>(_ addresses: [String],
                                  expectedIdentity: String,
                                  probe: (String) async throws -> (String, T)) async throws -> (String, T) {
        var failures: [(url: String, error: Error)] = []
        var seen = Set<String>()
        for url in addresses where seen.insert(url).inserted {
            try Task.checkCancellation()
            do {
                let result = try await probe(url)
                try Task.checkCancellation()
                if result.0 != expectedIdentity {
                    throw NSError(domain: "RemoteTool", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "设备标识不匹配，连接到了另一台电脑"])
                }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append((url, error))
            }
        }
        if failures.count == 1, let only = failures.first { throw only.error }
        throw DeviceAddressFailure(attempts: failures)
    }
}

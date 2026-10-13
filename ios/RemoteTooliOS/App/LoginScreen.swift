import SwiftUI

/// 登录页。对应 Android `NativeApp.kt` 的 `LoginScreen`：
/// 用户名从本地加密凭据里回填，密码每次手输（永不回显）。
struct LoginScreen: View {
    let session: Session

    @EnvironmentObject private var model: NativeModel
    @State private var username: String
    @State private var password = ""
    @State private var busy = false
    @State private var errorText: String? = nil

    /// 用户名不是秘密，直接放 UserDefaults；密码永远只在 Keychain 密文里。
    private var usernameKey: String { "login.username.\(session.device.id)" }

    init(session: Session) {
        self.session = session
        // 初始化时拿不到 EnvironmentObject，所以这里直接读一次加密凭据库补上「上次用的用户名」。
        let remembered = UserDefaults.standard.string(forKey: "login.username.\(session.device.id)") ?? ""
        let stored = DeviceCredentialStore().storedUsername(session.device.id)
        _username = State(initialValue: remembered.isEmpty ? stored : remembered)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
                Text("登录电脑").font(.system(size: 26, weight: .semibold))
                Text(session.api.base)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)

                SectionCard("账号") {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .textFieldStyle(.roundedBorder)
                    SecureField("密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                }

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }

                Button {
                    submit()
                } label: {
                    Text(busy ? "正在登录…" : "登录").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)

                Button("切换设备") { model.showDevices() }
                    .font(.system(size: 13))

                Text("密码只以 AES-GCM 密文保存在本机 Keychain，不会写入日志或任何请求头以外的位置。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func submit() {
        busy = true
        errorText = nil
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        Task {
            do {
                try await model.login(session, username: user, password: secret)
                UserDefaults.standard.set(user, forKey: usernameKey)
                password = ""
            } catch {
                errorText = connectionFailureMessage(error)
            }
            busy = false
        }
    }
}

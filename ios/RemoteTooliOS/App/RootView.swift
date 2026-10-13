import SwiftUI

/// 顶层路由。对应 Android `NativeApp` 的状态分发：
/// 未连接 → 设备列表；已连接但未登录 → 登录页；已连接已登录 → 主页。
/// `browsingDevices` 为真时即使已连接也回到设备列表（对应「我的设备」入口）。
struct RootView: View {
    @EnvironmentObject private var model: NativeModel
    @State private var remotePresentation: RemotePresentation?

    #if DEBUG
    @State private var showDebugPanel = false
    #endif

    private struct RemotePresentation: Identifiable {
        let id = UUID()
        let endpoint: String
        let cookie: String
    }

    var body: some View {
        ZStack {
            content

            if model.connecting {
                connectingOverlay
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.connecting)
        #if DEBUG
        .onAppear { showDebugPanel = DebugFlags.autoOpenPanel }
        .sheet(isPresented: $showDebugPanel) { RemoteToolDebugPanel() }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let session = model.session, !model.browsingDevices {
            if model.loginNeeded {
                LoginScreen(session: session)
            } else {
                HomeScreen(session: session) {
                    remotePresentation = RemotePresentation(endpoint: session.api.base,
                                                            cookie: session.api.cookie())
                }
                .fullScreenCover(item: $remotePresentation) { presentation in
                    RemoteControlScreen(endpoint: presentation.endpoint, cookie: presentation.cookie)
                }
            }
        } else {
            DevicesScreen()
        }
    }

    private var connectingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView().progressViewStyle(.circular)
            Text("正在连接设备…")
                .font(.system(size: 14))
            Button("取消") { model.disconnect() }
                .font(.system(size: 14))
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

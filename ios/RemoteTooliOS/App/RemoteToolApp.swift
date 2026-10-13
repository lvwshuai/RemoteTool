import SwiftUI
import UIKit

@main
struct RemoteToolApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = NativeModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                // Android 侧用的是 `Theme.Material.NoActionBar`（深色 Material 主题），
                // 这里保持同一观感，避免两端截图对比时对不上。
                .preferredColorScheme(.dark)
        }
    }
}

/// 需要 AppDelegate 只为一件事：让 `AppOrientation` 能动态决定支持的屏幕方向，
/// 对应 Android 远程页里的 `setRequestedOrientation`。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppOrientation.mask
    }
}

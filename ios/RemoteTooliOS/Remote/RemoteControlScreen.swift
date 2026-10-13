import SwiftUI
import UIKit

/// 远程桌面全屏页。
/// 对应 Android `RemoteActivity`：沉浸式横屏 + 顶部 / 底部工具栏 + 自动隐藏 + 画质切换 + 实时指标。
struct RemoteControlScreen: View {
    @StateObject private var controller: RemoteController
    @Environment(\.dismiss) private var dismiss

    @State private var showQualityPicker = false
    @State private var showTextComposer = false
    @State private var textDraft = ""
    @State private var showImeField = false

    init(endpoint: String, cookie: String) {
        _controller = StateObject(wrappedValue: RemoteController(endpoint: endpoint, cookie: cookie))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 5 / 255, green: 10 / 255, blue: 17 / 255)
                    .ignoresSafeArea()

                RemoteSurface(controller: controller)
                    .ignoresSafeArea()

                if showImeField {
                    // 透明输入框：只为拉起系统输入法并把文本转发给远程电脑。
                    RemoteKeyboardField(
                        onText: { controller.sendText($0) },
                        onBackspace: { count in
                            for _ in 0..<min(count, 64) { controller.tapKey(8) }
                        },
                        onReturn: { controller.tapKey(13) }
                    )
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .position(x: 1, y: 1)
                }

                toolOverlay(proxy: proxy)
            }
            .onAppear {
                controller.updateToolLayout(availableWidth: proxy.size.width,
                                            availableHeight: proxy.size.height)
            }
            .onChange(of: proxy.size) { size in
                controller.updateToolLayout(availableWidth: size.width, availableHeight: size.height)
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onAppear {
            AppOrientation.apply(.landscape)
            controller.start()
        }
        .onDisappear {
            controller.stop()
            showImeField = false
            AppOrientation.apply(.all)
        }
        .confirmationDialog("画质 · 分辨率 / 上限码率 / 帧率",
                            isPresented: $showQualityPicker,
                            titleVisibility: .visible) {
            ForEach(0..<RemoteQuality.names.count, id: \.self) { index in
                Button(RemoteQuality.detail(index)) { controller.selectQuality(index) }
            }
            Button("取消", role: .cancel) { }
        }
        .sheet(isPresented: $showTextComposer) {
            textComposerSheet
        }
        .alert("提示", isPresented: Binding(
            get: { controller.transientMessage != nil },
            set: { if !$0 { controller.transientMessage = nil } })) {
            Button("知道了", role: .cancel) { controller.transientMessage = nil }
        } message: {
            Text(controller.transientMessage ?? "")
        }
    }

    // MARK: - 工具栏

    @ViewBuilder
    private func toolOverlay(proxy: GeometryProxy) -> some View {
        let railWidth = controller.railWidth(availableWidth: proxy.size.width,
                                             availableHeight: proxy.size.height)
        let useRails = controller.sideTools && railWidth > 0

        ZStack {
            if controller.toolsVisible {
                if useRails {
                    HStack(spacing: 0) {
                        verticalToolbar(items: leadingItems, width: railWidth)
                        Spacer(minLength: 0)
                        verticalToolbar(items: trailingItems, width: railWidth)
                    }
                } else {
                    VStack(spacing: 0) {
                        horizontalToolbar(items: leadingItems)
                        Spacer(minLength: 0)
                        horizontalToolbar(items: trailingItems)
                    }
                    .padding(.vertical, 6)
                }

                VStack {
                    Spacer()
                    metricsBar
                        .padding(.bottom, 2)
                }
            } else {
                HStack {
                    Spacer()
                    Button {
                        controller.showTools()
                    } label: {
                        Text("工具")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(red: 32 / 255, green: 53 / 255, blue: 71 / 255).opacity(0.66))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.trailing, 8)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: controller.toolsVisible)
    }

    private var leadingItems: [RemoteToolItem] {
        [
            RemoteToolItem(title: "返回") { dismiss() },
            RemoteToolItem(title: "适应") { controller.resetZoom() },
            RemoteToolItem(title: "横屏") { AppOrientation.apply(.landscape) },
            RemoteToolItem(title: "竖屏") { AppOrientation.apply(.portrait) },
            RemoteToolItem(title: controller.isTrackpad ? "触控板" : "直接触控") {
                controller.toggleTrackpad()
            },
            RemoteToolItem(title: RemoteQuality.name(controller.qualityIndex)) {
                showQualityPicker = true
            },
            RemoteToolItem(title: controller.statusText) { controller.reconnect() }
        ]
    }

    private var trailingItems: [RemoteToolItem] {
        [
            RemoteToolItem(title: "键盘") { showImeField = true },
            RemoteToolItem(title: "发送文本") { textDraft = ""; showTextComposer = true },
            RemoteToolItem(title: "右键") { controller.sendClick(button: 2) },
            RemoteToolItem(title: "左键") { controller.sendClick(button: 0) },
            RemoteToolItem(title: "上滚") { controller.sendWheel(delta: 120) },
            RemoteToolItem(title: "下滚") { controller.sendWheel(delta: -120) },
            RemoteToolItem(title: controller.isCtrlHeld ? "Ctrl ✓" : "Ctrl",
                           highlighted: controller.isCtrlHeld) { controller.toggleModifier(17) },
            RemoteToolItem(title: controller.isAltHeld ? "Alt ✓" : "Alt",
                           highlighted: controller.isAltHeld) { controller.toggleModifier(18) },
            RemoteToolItem(title: "Esc") { controller.tapKey(27) },
            RemoteToolItem(title: "Enter") { controller.tapKey(13) },
            RemoteToolItem(title: "Tab") { controller.tapKey(9) }
        ]
    }

    private func horizontalToolbar(items: [RemoteToolItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    RemoteToolButton(item: item) { controller.showTools() }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(red: 16 / 255, green: 29 / 255, blue: 42 / 255).opacity(0.73))
    }

    private func verticalToolbar(items: [RemoteToolItem], width: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    RemoteToolButton(item: item, compact: true) { controller.showTools() }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .frame(width: width)
        .background(Color(red: 16 / 255, green: 29 / 255, blue: 42 / 255))
    }

    private var metricsBar: some View {
        Text(controller.metricsText)
            .font(.system(size: 11))
            .foregroundColor(Color(red: 211 / 255, green: 230 / 255, blue: 242 / 255))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(red: 16 / 255, green: 29 / 255, blue: 42 / 255).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(controller.metricsText.isEmpty ? 0 : 1)
    }

    private var textComposerSheet: some View {
        NavigationStack {
            TextEditor(text: $textDraft)
                .font(.system(size: 15))
                .padding(8)
                .navigationTitle("发送文字到电脑")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showTextComposer = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("发送") {
                            controller.sendText(textDraft)
                            showTextComposer = false
                        }
                        .disabled(textDraft.isEmpty)
                    }
                }
        }
    }
}

// MARK: - 工具栏按钮

struct RemoteToolItem {
    let title: String
    var highlighted: Bool = false
    let action: () -> Void
}

private struct RemoteToolButton: View {
    let item: RemoteToolItem
    var compact = false
    let onTouch: () -> Void

    var body: some View {
        Button {
            // 与 Android 一致：任何工具按钮点击都先 showTools()，再执行动作。
            onTouch()
            item.action()
        } label: {
            Text(item.title)
                .font(.system(size: compact ? 12 : 14))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: compact ? .infinity : nil)
                .padding(.horizontal, compact ? 4 : 14)
                .padding(.vertical, compact ? 4 : 10)
                .frame(height: compact ? 44 : nil)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(item.highlighted
                              ? Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
                              : Color(red: 38 / 255, green: 61 / 255, blue: 81 / 255).opacity(0.85))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 系统输入法转发

/// 透明 `UITextField`：把系统输入法提交的文字转发到远程电脑。
///
/// 对应 Android `RemoteView.onCreateInputConnection` 里的 `BaseInputConnection`：
/// `commitText` → 发送文本；`deleteSurroundingText` → 退格；`performEditorAction` → 回车。
/// iOS 用 `shouldChangeCharactersIn` 达到同样的效果，并且**不经过电脑剪贴板**。
struct RemoteKeyboardField: UIViewRepresentable {
    let onText: (String) -> Void
    let onBackspace: (Int) -> Void
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .default
        field.keyboardType = .default
        field.textColor = .clear
        field.tintColor = .clear
        field.backgroundColor = .clear
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        if !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: RemoteKeyboardField

        init(_ parent: RemoteKeyboardField) { self.parent = parent }

        func textField(_ textField: UITextField,
                       shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            // 始终返回 false：远程电脑只需要增量，本地不留文本。
            if string.isEmpty {
                if range.length > 0 { parent.onBackspace(range.length) }
            } else {
                parent.onText(string)
            }
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onReturn()
            return false
        }
    }
}

// MARK: - 方向控制

/// SwiftUI 没有直接强制屏幕方向的 API，这里通过 AppDelegate 的
/// `supportedInterfaceOrientationsFor` + `UIWindowScene.requestGeometryUpdate` 组合实现，
/// 与 Android 的 `setRequestedOrientation` 语义对应。
enum AppOrientation {
    static var mask: UIInterfaceOrientationMask = .all

    static func apply(_ value: UIInterfaceOrientationMask) {
        mask = value
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: value)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

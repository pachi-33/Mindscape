import AppKit
import SwiftUI

@MainActor
final class UpdateWindowController {
    static let shared = UpdateWindowController()

    private var window: NSWindow?
    private var didPosition = false

    func show(checker: UpdateChecker) {
        if window == nil {
            let root = UpdateWindowView(onClose: { [weak self] in
                self?.window?.close()
            })
            .environment(checker)

            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "软件更新")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 500, height: 380))
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        if let window {
            let screen = hostScreen()
            if !didPosition {
                position(window, on: screen)
                didPosition = true
            } else if let screen, !screen.visibleFrame.intersects(window.frame) {
                position(window, on: screen)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// 多显示器 / 虚拟屏下 `center()` 可能把窗口放到屏幕外，跟随主窗口所在屏幕。
    private func hostScreen() -> NSScreen? {
        if let main = NSApp.windows.first(where: { $0.title == "Mindscape" && $0.isVisible })?.screen {
            return main
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func position(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }
}

struct UpdateWindowView: View {
    @Environment(UpdateChecker.self) private var updates
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("软件更新", systemImage: "arrow.down.circle")
                .font(.title2)
            Text("当前版本：\(updates.installedVersionDescription)")
                .foregroundStyle(.secondary)
            Divider()

            switch updates.phase {
            case .available:
                if let release = updates.release {
                    Text("Mindscape \(release.version.description) 可用").font(.headline)
                    if !release.notes.isEmpty {
                        ScrollView {
                            Text(release.notes).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text("更新完成后，Mindscape 会自动重新打开。")
                    .foregroundStyle(.secondary)
            case .checking, .verifying, .installing:
                ProgressView(updates.statusDescription)
            case .downloading(let progress):
                if let progress {
                    ProgressView(value: progress) { Text("正在下载…") }
                } else {
                    ProgressView("正在下载…")
                }
            case .failed(let error):
                Label("更新失败", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(error).fixedSize(horizontal: false, vertical: true)
            case .idle, .upToDate:
                Text(updates.statusDescription)
            }

            Spacer()
            HStack {
                Button("打开发布页") { updates.openReleasePage() }
                Spacer()
                if updates.canCancel {
                    Button("取消") { updates.cancel() }
                } else if !updates.phase.isUpdating, updates.phase != .checking {
                    Button("关闭", action: onClose)
                    if updates.phase == .available {
                        Button {
                            updates.install()
                        } label: {
                            Text("更新", tableName: "SoftwareUpdate")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(updates.phase == .idle ? "检查更新" : "重新检查") {
                            updates.check(manual: true)
                        }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 500, height: 380)
    }
}

import AppKit
import SwiftUI

/// 把属性面板开关固定在窗口标题栏最右侧。
struct InspectorTitlebarToggle: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let anchor = WindowAnchorView(frame: .zero)
        anchor.onWindowChange = { window in
            if let window {
                context.coordinator.install(in: window)
            } else {
                context.coordinator.uninstall()
            }
        }
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator: NSObject {
        private var accessory: NSTitlebarAccessoryViewController?
        private weak var window: NSWindow?

        func install(in window: NSWindow) {
            guard self.window !== window else { return }
            uninstall()

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 48, height: 28))
            let button = InspectorTitlebarButton(frame: NSRect(x: 10, y: 0, width: 28, height: 28))
            let title = String(localized: "显示 / 隐藏属性面板")
            button.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: title)
            button.imagePosition = .imageOnly
            button.bezelStyle = .accessoryBarAction
            button.target = self
            button.action = #selector(toggleInspector)
            button.toolTip = String(localized: "显示 / 隐藏属性面板（⌥⌘I）")
            button.setAccessibilityLabel(title)
            button.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            container.addSubview(button)

            let controller = NSTitlebarAccessoryViewController()
            controller.view = container
            controller.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(controller)

            accessory = controller
            self.window = window
        }

        @objc private func toggleInspector() {
            NotificationCenter.default.post(name: .mindscapeToggleInspector, object: nil)
        }

        func uninstall() {
            if let accessory, let window,
               let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            accessory = nil
            window = nil
        }
    }
}

private final class WindowAnchorView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

private final class InspectorTitlebarButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

import AppKit
import SwiftUI

struct AppCommands: Commands {
    @Environment(\.openSettings) private var openSettings

    let app: AppModel
    @ObservedObject var shortcuts: ShortcutStore

    init(app: AppModel) {
        self.app = app
        self._shortcuts = ObservedObject(wrappedValue: app.shortcuts)
    }

    private var hasTreeEditor: Bool { app.editor?.map.isSequence == false }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                UpdateWindowController.shared.show(checker: app.updates)
                app.updates.check(manual: true)
            }

            Button("AI Agent 接入…") {
                SettingsRouter.shared.requestedTab = .agent
                openSettings()
            }
        }

        CommandGroup(replacing: .newItem) {
            Menu("新建导图") {
                Button("空白思维导图") {
                    app.createDocument(template: .blank)
                }
                .accessibilityIdentifier("newDocument.blank")
                .appShortcut(shortcuts.combo(for: .newDocument))

                Button("UML 时序图") {
                    app.createDocument(template: .sequence)
                }
                .accessibilityIdentifier("newDocument.sequence")
            }
            .disabled(app.updates.isPreparingApplication)

            Button("导入 Markdown / OPML / JSON…") {
                app.importDocument()
            }
            .disabled(app.updates.isPreparingApplication)
            .appShortcut(shortcuts.combo(for: .importDocument))
        }

        CommandGroup(replacing: .undoRedo) {
            Button("撤销") {
                app.editor?.undo()
            }
            .disabled(app.updates.isPreparingApplication)
            .appShortcut(shortcuts.combo(for: .undo))

            Button("重做") {
                app.editor?.redo()
            }
            .disabled(app.updates.isPreparingApplication)
            .appShortcut(shortcuts.combo(for: .redo))

            Divider()

            Button {
                NotificationCenter.default.post(name: .mindscapeFind, object: nil)
            } label: {
                if app.editor?.map.isSequence == true {
                    Text("查找时序元素…")
                } else {
                    Text("查找节点…")
                }
            }
            .disabled(app.editor == nil)
            .appShortcut(shortcuts.combo(for: .findNode))

            Button("创建副本") {
                app.editor?.duplicateSelection()
            }
            .disabled(!hasTreeEditor || app.updates.isPreparingApplication)
            .appShortcut(shortcuts.combo(for: .duplicateNode))
        }

        CommandGroup(replacing: .saveItem) {
            Button("保存") {
                app.editor?.saveNow()
            }
            .appShortcut(shortcuts.combo(for: .saveDocument))
        }

        CommandMenu("导图") {
            Button("导出…") {
                NotificationCenter.default.post(name: .mindscapeShowExport, object: nil)
            }
            .appShortcut(shortcuts.combo(for: .exportDocument))

            Button("历史版本…") {
                NotificationCenter.default.post(name: .mindscapeShowHistory, object: nil)
            }
            .appShortcut(shortcuts.combo(for: .showHistory))

            Button("创建快照") {
                let success = app.editor?.createSnapshot() ?? false
                NotificationCenter.default.post(
                    name: .mindscapeSnapshotCreated,
                    object: success
                )
            }

            Divider()

            Button("显示 / 隐藏大纲") {
                NotificationCenter.default.post(name: .mindscapeToggleOutline, object: nil)
            }
            .disabled(app.editor == nil)
            .appShortcut(shortcuts.combo(for: .toggleOutline))

            Divider()

            Button("专注当前分支") {
                app.editor?.toggleFocus()
            }
            .disabled(!hasTreeEditor)
            .appShortcut(shortcuts.combo(for: .focusMode))

            Button("缩放到分支") {
                app.editor?.requestZoomToBranch()
            }
            .disabled(!hasTreeEditor)
            .appShortcut(shortcuts.combo(for: .zoomToBranch))

            Button("折叠全部子分支") {
                app.editor?.collapseAll()
            }
            .disabled(!hasTreeEditor || app.updates.isPreparingApplication)
            .appShortcut(shortcuts.combo(for: .collapseAll))

            Button("展开全部") {
                app.editor?.expandAll()
            }
            .disabled(!hasTreeEditor || app.updates.isPreparingApplication)
            .appShortcut(shortcuts.combo(for: .expandAll))

            Divider()

            Button("演示模式") {
                NotificationCenter.default.post(name: .mindscapePresent, object: nil)
            }
            .disabled(!hasTreeEditor)
            .appShortcut(shortcuts.combo(for: .presentMode))

            Divider()

            Button("适配画布") {
                app.editor?.requestFit()
            }
            .disabled(app.editor == nil)
            .appShortcut(shortcuts.combo(for: .fitCanvas))

            Button("居中画布") {
                app.editor?.requestCenterContent()
            }
            .disabled(app.editor == nil)
            .appShortcut(shortcuts.combo(for: .centerCanvas))

            Button("放大") {
                app.editor?.requestZoom(1.2)
            }
            .disabled(app.editor == nil)
            .appShortcut(shortcuts.combo(for: .zoomIn))

            Button("缩小") {
                app.editor?.requestZoom(0.83)
            }
            .disabled(app.editor == nil)
            .appShortcut(shortcuts.combo(for: .zoomOut))

            Divider()

            Button("显示 / 隐藏属性面板") {
                NotificationCenter.default.post(name: .mindscapeToggleInspector, object: nil)
            }
            .disabled(app.editor == nil)
            .appShortcut(shortcuts.combo(for: .toggleInspector))

            Divider()

            Menu("布局") {
                ForEach(MapLayout.allCases) { layout in
                    Button(layout.title) {
                        app.editor?.setLayout(layout)
                    }
                }
                if app.editor?.map.layout == .mindMap {
                    Divider()
                    ForEach(MindMapLayoutMode.allCases) { mode in
                        Button(mode.title) {
                            app.editor?.setMindMapLayoutMode(mode)
                        }
                    }
                }
            }
            .disabled(!hasTreeEditor)

            Menu("主题") {
                ForEach(MapTheme.all.filter {
                    ThemePolicy.allows($0.id, isDark: NSApplication.shared.isDarkAppearance)
                }) { theme in
                    Button(theme.name) {
                        app.editor?.setTheme(theme.id)
                    }
                }
            }
            .disabled(app.editor == nil)

            Divider()

        }
    }
}

# 工作区与演示现状设计

本文记录 0.7.0 代码基线中工作区、导航、外观设置和演示模式的实现；用户可观察行为见 [工作区与演示规格](../../openspec/specs/workspace-presentation/spec.md)。结论来自源码和现有测试的静态阅读，本次未运行 XCTest 或人工验证所有界面路径。

## 界面组成与状态

- [MindscapeApp](../../Mindscape/App/MindscapeApp.swift) 创建主窗口、设置窗口和菜单栏入口，并向视图注入 `AppModel`。[RootView](../../Mindscape/Views/RootView.swift) 使用 `NavigationSplitView` 组合侧栏和工作区；没有当前编辑器时显示空状态。
- [AppModel](../../Mindscape/App/AppModel.swift) 是主线程上的可观察应用状态，持有文档、目录、当前选择及当前 `MapEditor`。[SidebarView](../../Mindscape/Views/SidebarView.swift) 读取文件夹树、收藏和搜索结果；文档搜索针对标题和存储的预览字段，不是全文索引。
- [WorkspaceView](../../Mindscape/Views/WorkspaceView.swift) 组合画布、大纲、属性面板、搜索条、历史和导出界面。画布、大纲及属性面板共享同一个 `MapEditor`；面板开关、搜索位置和提示等视图状态由工作区维护。
- [AppCommands](../../Mindscape/App/AppCommands.swift) 结合 `ShortcutStore` 注册菜单操作；部分视图动作通过 `NotificationCenter` 通知工作区。`CanvasBridge` 将定位和焦点请求转发给 AppKit 画布。

## 文档导航、大纲与搜索

侧栏默认按文件夹层级显示文档；收藏或搜索时显示平面筛选结果。搜索使用 `localizedCaseInsensitiveContains` 匹配文档标题与预览；预览由存储层从导图前 24 个节点文字生成，因此不能视为所有节点的全文搜索。删除目录的界面提示说明内容上移，具体数据操作由存储层实现。

[OutlineView](../../Mindscape/Views/OutlineView.swift) 从每个头部递归显示子节点，读取同一个模型中的折叠状态。点击行会选中节点并通过桥接请求画布定位；折叠按钮也修改共享编辑器。大纲没有节点文字编辑入口，递归显示深度有 200 层上限。

图内搜索由 `MapEditor.searchMatches` 按广度优先顺序匹配节点文字、备注、图标符号及可识别的图标名称。工作区维护当前匹配项，并把匹配集合传给画布；这与侧栏文档搜索是两套范围和数据来源。

## 外观、主题、快捷键与本地化

- [AppearanceMode](../../Mindscape/Support/AppearanceMode.swift) 提供跟随系统、浅色及深色。`AppModel` 将外观选择存入 `UserDefaults` 并应用到应用。
- [MapTheme / ThemePolicy](../../Mindscape/Models/MapTheme.swift) 定义八套画布主题和明暗匹配规则。[MindMap](../../Mindscape/Models/MindMap.swift) 保存浅色和深色主题对；旧数据只有一个 `themeID` 时，通过 `normalizeTheme` 构造一对主题，另一侧回退到纸白或深空。
- [ShortcutStore](../../Mindscape/Support/ShortcutStore.swift) 保存可配置快捷键和多选修饰键，按菜单/画布作用域匹配事件，校验冲突、空组合、菜单修饰键及 Command-Q。代码还包含针对旧默认快捷键的迁移。
- 应用以中文为开发语言，英文翻译放在 [en.lproj](../../Mindscape/en.lproj/) 中；界面通过 `String(localized:)` 等系统本地化能力获取文本。具体翻译覆盖程度以资源文件为准。

## 演示窗口

[PresentationWindow.swift](../../Mindscape/Presentation/PresentationWindow.swift) 复制当前 `MindMap` 创建独立 `PresentationModel`，并为该模型提供内存 `DocumentStore` 和只读画布。第一页是全图总览；之后沿广度优先顺序为每个一级分支，以及其他具有子节点的非头部节点生成页面。翻页会更新选区、焦点及分支适配，方向键、空格、回车和 Escape 由窗口内事件监听器处理；关闭时释放监听器、窗口与模型。

当前 [README](../../README.md) 将演示分页概括为“按一级分支自动生成分页”，代码实际上还包含更深层的非叶子节点。该差异记录为文档待核实项，不在基线中假定其中一方应当改变。

## 验证依据与边界

- [MindscapeCoreTests.swift](../../MindscapeTests/MindscapeCoreTests.swift) 的 `testSearchMatchesTextNoteAndIcon`、`testPresentationSlides`、`testEnglishLocalizationBundled` 和 `testSelectionModifierCanBeChangedToCommand` 覆盖部分模型或视图行为。
- [ThemePolicyTests.swift](../../MindscapeTests/ThemePolicyTests.swift) 覆盖明暗主题匹配、旧主题数据和外观切换时主题记忆。
- 上述测试是现有源码中的回归依据，本次未执行。侧栏完整点击流程、大纲和画布同步、不同系统语言及演示窗口的键盘操作仍宜在实际 macOS UI 中验证。

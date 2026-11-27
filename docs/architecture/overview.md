# Mindscape 现状架构基线

本基线依据当前仓库源码、现有测试与工程配置整理，参考版本为 `project.yml` 中的 0.7.0、Git 提交 `258dfe9`。它记录当前实现和可观察行为；引用测试表示仓库中存在相应测试，并不表示本次整理已运行这些测试。发现的实现风险和待确认行为单独列出，不作为预期功能承诺。

## 产品与构建边界

Mindscape 是本地优先的 macOS 应用，最低系统版本为 macOS 14。工程使用 Swift 5 语言模式、SwiftUI、AppKit、Observation、Core Graphics 与系统 SQLite；[project.yml](../../project.yml) 由 XcodeGen 生成 Xcode 工程，包含应用、CLI 和 XCTest 三个 target。`AgentSkill/` 作为应用资源打包，仓库的 `openspec/` 和 `.agents/skills/openspec-*` 属于开发流程文件。

## 主要数据流

```text
SwiftUI 窗口 / 侧栏 / 属性面板
              |
              v
        AppModel --> MapEditor --> MindMap / MindNode
            |             |
            |             +--> 布局、绘制、NSView 画布
            v
       DocumentStore --> SQLite (文档 JSON、目录、快照)
            ^
            |
CLI / 本地 HTTP --> AgentService --> 外部修改后的界面刷新

UpdateChecker --> GitHubUpdateService --> GitHub Releases
```

应用入口 [MindscapeApp.swift](../../Mindscape/App/MindscapeApp.swift) 建立主窗口、设置窗口和菜单栏入口，并注入 [AppModel](../../Mindscape/App/AppModel.swift)。AppModel 持有当前 `DocumentStore` 和 `MapEditor`；画布通过 [WorkspaceView](../../Mindscape/Views/WorkspaceView.swift) 中的 `NSViewRepresentable` 接入 SwiftUI。`MapEditor` 负责编辑状态、撤销和保存调度；布局计算与绘制由 `Canvas/` 中的独立类型承担。

Agent 服务通过本机 HTTP 接收请求，在主线程的 `AgentService` 中访问存储，并回调 AppModel 刷新界面；它与界面共用文档存储，但请求不是经由当前 `MapEditor` 执行。详细行为和限制见 [Agent 网关与 CLI](agent-gateway.md)。

## 应用启动与失败回退

- AppModel 按配置打开数据目录，读取文档和目录列表；有可打开的文档时选择列表首项。
- 自定义数据目录打开失败时尝试默认目录并提示；无法打开磁盘数据库且内存数据库创建成功时，使用内存数据库，并提示本次修改不会持久化。内存数据库创建本身使用 `try!`。
- 应用失活或即将退出时对当前编辑器调用 `saveNow()`；该操作内部的保存错误目前被捕获，不会向调用方返回结果。
- 主界面按自动更新询问、Agent 接入询问的顺序处理首次运行提示；画布提示等待首启提示流程结束。

依据：[AppModel.swift](../../Mindscape/App/AppModel.swift)、[RootView.swift](../../Mindscape/Views/RootView.swift)、[FirstRunPromptCoordinator.swift](../../Mindscape/Support/FirstRunPromptCoordinator.swift)。

## 状态与并发

`AppModel`、`MapEditor`、`DocumentStore` 和 `AgentService` 标注为 `@MainActor`。Agent HTTP 服务在后台队列接收连接，请求处理再桥接到主线程；更新检查及文件下载使用异步任务，校验计算在后台进行。画布为自绘 AppKit `NSView`，布局及可见帧由画布相关组件管理。

## 本地数据与配置

默认数据库位于用户 Application Support 的 `Mindscape/mindscape.sqlite`；应用支持使用其他数据目录。SQLite 数据库保存导图主体 JSON、列表所需元数据、目录和历史快照；部分应用偏好保存在 `UserDefaults`。数据库与导入导出格式的详细边界见 [文档与存储](storage.md) 和 [导入导出](import-export.md)。

## 子系统索引

| 子系统 | 现状设计 | 能力规格 |
|---|---|---|
| 应用启动与更新 | [应用生命周期与更新](application-updates.md) | [生命周期](../../openspec/specs/application-lifecycle/spec.md)、[应用更新](../../openspec/specs/application-updates/spec.md) |
| 文档存储与历史 | [文档与存储](storage.md) | [文档存储](../../openspec/specs/document-storage/spec.md) |
| 导图模型与编辑 | [导图模型与编辑](editor.md) | [导图编辑](../../openspec/specs/mind-map-editing/spec.md) |
| 画布与布局 | [画布与布局](canvas.md) | [画布交互](../../openspec/specs/canvas-interaction/spec.md) |
| 工作区与演示 | [工作区与演示](workspace-presentation.md) | [工作区与演示](../../openspec/specs/workspace-presentation/spec.md) |
| UML 时序图 | [图形编辑与绘图设计](../../openspec/changes/archive/2026-11-27-add-uml-sequence-diagrams/design.md) | [时序图规格](../../openspec/specs/uml-sequence-diagrams/spec.md) |
| Agent 和 CLI | [Agent 网关与 CLI](agent-gateway.md) | [Agent 网关](../../openspec/specs/agent-gateway/spec.md) |
| 导入导出 | [导入导出](import-export.md) | [导入导出](../../openspec/specs/import-export/spec.md) |

## 基线维护

规格记录希望保留且已与当前实现核对的行为；设计文档解释其实现边界。新需求和有意改变现状的修复应通过独立 OpenSpec 变更描述，实施并验收后同步主规格和相关设计。测试文件和源码是核对依据，README 与实现不一致的地方应作为待确认项处理。

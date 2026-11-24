# 文档存储与历史：现状设计

本文记录当前代码的存储实现，行为要求见 [文档存储与历史规格](../../openspec/specs/document-storage/spec.md)。结论来自源码和测试代码的静态阅读；本次整理未运行 XCTest。

## 职责与入口

- [AppModel](../../Mindscape/App/AppModel.swift) 在主线程持有当前 `DocumentStore`，负责打开文档、维护列表及切换数据目录。
- [DocumentStore](../../Mindscape/Storage/DocumentStore.swift) 在主线程执行文档、目录与快照读写，负责数据库迁移及复制。
- [SQLiteDatabase](../../Mindscape/Storage/SQLiteDatabase.swift) 封装系统 SQLite 的连接、参数绑定和查询；文件数据库请求使用 WAL，并设置 `synchronous=NORMAL`、外键及 3000ms busy timeout。内存数据库的日志模式由 SQLite 决定。
- [MapEditor](../../Mindscape/Editor/MapEditor.swift) 持有当前导图的内存状态，调度自动保存和快照。[HistoryView](../../Mindscape/Views/HistoryView.swift) 使用编辑器提供的历史接口。

## 数据组织

默认数据库位于用户应用支持目录的 `Mindscape/mindscape.sqlite`；自定义目录路径保存在 `UserDefaults` 的 `dataDirectory`。每个数据目录各有一份库。测试还可以创建 `:memory:` 库。

| 表 | 当前用途 |
|---|---|
| `documents` | 主键、完整导图 JSON、标题、布局、主题、收藏、时间、删除标记、目录、节点数和预览。预览取前 24 个节点文本。 |
| `folders` | 目录 ID、名称、父目录、顺序及创建时间。 |
| `snapshots` | 所属文档、名称、类型、完整导图 JSON、创建时间和节点数。外键开启级联删除。 |
| `settings` | 迁移时创建的键值表；本次阅读的文档读写路径未使用它存放应用偏好。 |

导图主体由 `JSONEncoder` 编码为文本。文档列表所需信息冗余在列中；保存已有文档时更新主体与相关元数据，收藏和删除状态由独立操作维护，目录移动使用独立更新。

## 读写与生命周期

1. `AppModel.selectDocument` 先请求当前编辑器保存，随后从库读取目标导图并新建编辑器。
2. `MapEditor` 的普通模型修改调用 `scheduleSave`；每次取消上一个任务并等待 600ms，再调用 `saveNow`。应用失去活动状态或即将退出时也请求立即保存。
3. `saveNow` 成功写入后检查自动快照并通知列表刷新。自动快照是在距上次计时超过 10 分钟后的下一次成功保存时尝试创建，并非独立定时器。
4. 快照保留完整导图 JSON。自动快照写入后尝试清理超过最近 20 条的同类记录；插入与清理不在同一事务中，清理失败时可能已经插入新快照。列表查询返回最近 60 条，包含手动和自动类型。恢复时尝试先创建“恢复前”手动快照，再保留当前文档 ID 恢复内容；该次恢复加入撤销栈。
5. 删除目录通过 `BEGIN IMMEDIATE` 事务将其直接文档和子目录上移，再删除目录；失败时尝试回滚。移动文档则直接更新 `folder_id`。
6. 切换目录前请求保存当前编辑器。选择复制时，`exportDatabase` 先检查目标文件不存在，再执行 WAL checkpoint 和 `VACUUM INTO`；成功后打开新库并刷新列表。原库不会在该路径中删除。

## 迁移与兼容

启动时按 `PRAGMA user_version` 执行迁移：版本 1 建立文档、快照及设置表，版本 2 建立目录表并在缺失时增加 `documents.folder_id`。导图 JSON 的节点兼容性由 [MindNode](../../Mindscape/Models/MindNode.swift) 处理，包括旧 `emoji` 图标字段；`MindMap` 中未记录的布局模式按“记住布局”处理。当前代码没有为每个未来版本提供通用回滚机制。

## 错误与待核验边界

- 初次打开自定义库失败时，`AppModel` 尝试回退默认目录；若仍失败且内存库可用，则使用内存库并提示本次修改不会保存。内存库创建使用 `try!`。
- `MapEditor.saveNow` 捕获并静默处理保存错误，自动快照和恢复前快照也使用尽力尝试；不能据此断言失败时用户一定收到提示，或恢复前留档一定成功。
- `AppModel.reloadAfterExternalChange` 在 Agent 修改当前文档后重建编辑器，且注释明确避免旧编辑器主动保存。界面尚有等待保存的变更与 Agent 并发修改的交互，需要专门的集成回归验证。
- 已运行的 Agent 服务持有启动时的 store；数据目录切换后服务是否需要重新绑定，以及两者并发时的行为，需要集成验证，不能仅凭文档视为已解决。

## 已有测试与覆盖线索

- [MindscapeCoreTests.swift](../../MindscapeTests/MindscapeCoreTests.swift) 中 `testDocumentStoreTrashRestore` 覆盖内存库保存、回收站、恢复和彻底删除；`testSnapshotCreateRenameDelete` 覆盖手动快照的基础操作。
- 同文件的 `testMindMapLayoutFieldsRoundTripAndLegacyDecode` 覆盖相关 JSON 新旧字段解码。
- 目前上述测试代码并未覆盖所有目录删除事务、磁盘故障、数据库迁移或自动快照时序；这些属于后续验证项，不代表已经运行失败。

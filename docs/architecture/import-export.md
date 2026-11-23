# 导入与导出现状设计

## 范围与入口

本基线根据 0.7.0 源码和测试静态整理，覆盖图形界面、本机 Agent 和 CLI 对导图文件的导入、导出和分享。行为规格见 [import-export](../../openspec/specs/import-export/spec.md)。

| 组件 | 当前职责 |
| --- | --- |
| [MapImporter](../../Mindscape/Support/MapImporter.swift) | 读取文件并解析 Markdown、OPML/XML 或 Mindscape JSON，生成新导图。 |
| [ExportService](../../Mindscape/Support/ExportService.swift) | 将导图编码为文本或图像数据，提供保存面板、临时分享文件和系统分享面板。 |
| [AppModel](../../Mindscape/App/AppModel.swift) | 图形界面导入面板、标题去重、存储及选择；侧栏导出从存储读取导图。 |
| [ExportSheet](../../Mindscape/Views/ExportSheet.swift) | 对当前编辑器导图计算布局，选择导出格式、PNG 缩放、保存或分享。 |
| [AgentService](../../Mindscape/Agent/AgentService.swift) | 提供网关导入导出路由、路径校验、文件写入和存储刷新。 |
| [MindscapeCLI](../../MindscapeCLI/Main.swift) | 将导入、导出命令转换为网关请求；客户端不直接编辑数据库。 |

## 导入流程

1. 图形界面使用系统文件面板选择文件，调用 `MapImporter.load`。成功后由 AppModel 对标题去重、保存到当前目录、刷新列表并选择新导图；失败时通过应用提示显示错误。
2. Markdown 以 UTF-8 读取。解析器将标题和列表缩进映射为节点层级，引用行添加为最近节点的备注，跳过代码围栏内容；普通段落也转换为节点。
3. OPML 通过 `XMLParser` 解析 outline 的 `text`/`title`/`_text` 和备注。一个根 outline 映射为头部；多个根 outline 使用一个新建的公共头部。
4. JSON 使用 ISO 8601 日期解码为 `MindMap`，要求包含节点；导入时生成新的导图 ID、更新时间并应用传入主题。OPML 和 Markdown 导入同样创建新导图 ID。
5. Agent 导入使用相同的解析器，先验证路径和扩展名并解析文件，再在保存前验证可选的目录 ID；服务将导图标题设为源文件名，再保存并通知 App 刷新。

## 导出和分享流程

- `ExportFormat` 包含 PNG、PDF、Markdown、OPML、JSON。JSON 使用 ISO 8601 日期和格式化输出；Markdown 按根节点和子节点输出列表及备注；OPML 输出 outline 和备注属性。文本格式遍历各头部树，使用 visited 集合避免重复遍历。
- PNG/PDF 复用 `LayoutEngine` 的布局结果及 `MapRenderer`。PDF 由 `ExportCanvasView` 输出；PNG 先获得 PDF 图像，再按缩放生成位图。Agent 的 scale 默认 2，并限制在 1 至 3 之间。
- GUI 保存使用 `NSSavePanel` 和原子写入；分享先在系统临时目录生成文件，再交给 `NSSharingServicePicker`。导出面板使用当前 `editor.map`；侧栏快捷导出由 AppModel 从存储加载。
- Agent 导出先校验路径和扩展名，缺少扩展名时补上；计算布局并生成数据，创建必要父目录后原子写入。响应返回路径、格式和字节数。

## 文件与错误边界

- Agent 文件路径须为绝对路径或 `~` 开头；对父路径及目标解析符号链接后，检查路径位于用户目录或 `/tmp` 下。Agent 导入只接受 `md`、`markdown`、`opml`、`xml`、`json`；导出扩展名须对应选定格式。
- 导入器对不可读取或空文件、无效 OPML、无效/空节点 JSON 返回错误。Agent 服务将解析错误统一包装为 HTTP 错误响应；GUI 用应用提示或导出错误提示展示失败。
- Markdown 和 OPML 是层级文本交换格式，不能视为完整视觉样式或全部内部字段的无损备份；多根 OPML 导入时会增加共同头部。JSON 更适合保存导图数据结构，但导入时仍会生成新的导图 ID。
- 当前项目不直接导入 `.xmind` / FreeMind 文件，相关能力和迁移说明见 [README](../../README.md)。

## 验证依据与待确认项

- [MindscapeCoreTests](../../MindscapeTests/MindscapeCoreTests.swift) 包含五种导出格式检查、Markdown/OPML 往返、层级和备注、多头部导出等测试。
- [AgentServiceTests](../../MindscapeTests/AgentServiceTests.swift) 包含批量创建后导出和受限路径拒绝测试。本次整理未运行 XCTest。
- GUI 文件面板、系统分享和不同环境中的路径/符号链接行为仍需结合实际环境验证；规格校验本身不能验证这些行为。
- Markdown 列表解析将 Tab 计作两个缩进单位，但截取原始字符串时使用该数值作为字符数；含 Tab 缩进的列表可能无法按预期识别。节点构建时一级标题用于标题处理并跳过，多个一级标题的处理也应单独验证。
- 路径检查会先解析符号链接，再与用户目录和字面量 `/tmp/` 前缀比较。本机 `/tmp` 指向 `/private/tmp`，因此通过 `/tmp` 指定的路径可能在解析后被拒绝；应通过集成测试确认，不应仅凭允许前缀推断其可用性。

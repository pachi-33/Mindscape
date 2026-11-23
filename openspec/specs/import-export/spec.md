# 导入与导出

## Purpose

允许用户通过图形界面或本机 Agent 将导图与常见文本、结构化数据和图片文档格式交换，并通过独立新文档导入已有内容。

## Requirements

### Requirement: 导入创建新导图

系统 SHALL 将支持的 Markdown、OPML 或 Mindscape JSON 文件导入为新的导图文档。

#### Scenario: 导入已有 JSON 导图

- **WHEN** 用户导入包含有效节点的 Mindscape JSON 文件
- **THEN** 导入结果获得新的导图 ID，不覆盖使用原 ID 的导图

#### Scenario: 图形界面选择导入文件

- **WHEN** 用户在导入面板选择受支持的文件，且文件读取、解析及保存均成功
- **THEN** 应用将新导图保存到当前选择的目录并尝试打开它

### Requirement: 解析 Markdown 层级和备注

Markdown 导入器 SHALL 依据现有解析规则将标题和以空格缩进的列表转换为节点层级，并将引用行作为最近节点的备注。

#### Scenario: 嵌套列表

- **WHEN** Markdown 列表包含按空格缩进嵌套的条目
- **THEN** 导入的节点按空格缩进建立相应的父子关系

#### Scenario: 引用作为备注

- **WHEN** 一个节点之后有非代码块内、内容非空的 Markdown 引用行
- **THEN** 引用内容成为该节点的备注

### Requirement: 解析 OPML 大纲

OPML 导入器 SHALL 从 outline 元素构建节点层级并读取支持的备注属性。

#### Scenario: 单个根大纲

- **WHEN** OPML 文件有一个文字非空的根 outline 及其子项
- **THEN** 该根 outline 的文本作为导图头部，子项保持其层级

#### Scenario: 多个根大纲

- **WHEN** OPML 文件有多个根 outline
- **THEN** 导入器创建一个共同头部并将各根 outline 作为其子项

### Requirement: 导出五种格式

系统 SHALL 支持将导图导出为 PNG、PDF、Markdown、OPML 和 JSON。

#### Scenario: 导出图片或文档

- **WHEN** 用户选择 PNG 或 PDF 并成功保存
- **THEN** 系统生成相应格式的画布文件

#### Scenario: 导出结构化数据

- **WHEN** 用户选择 JSON 并成功保存
- **THEN** 系统以 ISO 8601 日期格式编码导图数据

### Requirement: 文本导出包含多棵头部树

Markdown 和 OPML 导出 SHALL 遍历导图中的各个头部节点及其子树。

#### Scenario: 导图有多个头部节点

- **WHEN** 用户将包含多个头部节点的导图导出为 Markdown 或 OPML
- **THEN** 导出内容包含各头部节点及可遍历的子节点

### Requirement: 支持系统分享

系统 SHALL 能将选定格式生成临时文件并交给 macOS 系统分享面板。

#### Scenario: 分享生成成功

- **WHEN** 用户在导出界面选择分享、文件生成成功且存在可用于显示的窗口内容视图
- **THEN** 应用以生成的临时文件打开系统分享面板

### Requirement: Agent 文件操作限制路径和格式

本机 Agent 网关 SHALL 在导入和导出时检查文件路径，并限制可访问的位置与扩展名。

#### Scenario: 访问允许范围外的路径

- **WHEN** Agent 的请求体、操作、所需导图和扩展名通过前置校验，但路径校验发现文件不在用户目录或 `/tmp` 允许范围内
- **THEN** 网关拒绝请求并返回 HTTP 403

#### Scenario: 导入不支持的扩展名

- **WHEN** Agent 请求导入路径在允许范围内、文件存在但扩展名不是 `md`、`markdown`、`opml`、`xml` 或 `json` 的文件
- **THEN** 网关返回 HTTP 400

#### Scenario: 导出扩展名不匹配

- **WHEN** Agent 请求的格式有效、导图存在、输出路径为绝对路径或以 `~` 开头，但文件扩展名与所选格式不匹配
- **THEN** 网关返回 HTTP 400

### Requirement: 导入无效文件时报告失败

导入器 SHALL 拒绝无法读取的文件、无效 OPML 和不符合导图格式或没有节点的 JSON。

#### Scenario: 无效 JSON

- **WHEN** JSON 文件无法解码为包含节点的 Mindscape 导图
- **THEN** 导入失败并返回或显示导入错误

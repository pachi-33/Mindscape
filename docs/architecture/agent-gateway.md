# Agent 网关与 CLI 现状设计

## 范围

本基线根据 0.7.0 源码和测试静态整理，描述应用内 Agent 服务、命令行客户端、内置 Mindscape Skill 及其接入界面。行为规格见 [agent-gateway](../../openspec/specs/agent-gateway/spec.md)；与 OpenSpec 开发工作流使用的 Skill 是不同的资源。

## 职责与入口

| 组件 | 当前职责 |
| --- | --- |
| [AgentCoordinator](../../Mindscape/Agent/AgentCoordinator.swift) | 维护启用状态、启动/停止、空闲监测和网关描述文件；连接 App 与 HTTP 服务。 |
| [AgentHTTPServer](../../Mindscape/Agent/AgentHTTPServer.swift) | 基于 Darwin socket 监听、解析 HTTP/1.1、执行传输层限制和鉴权，再调用处理函数。 |
| [AgentService](../../Mindscape/Agent/AgentService.swift) | 在主线程路由 `/v1` 请求，操作 DocumentStore、导入导出和 Skill 安装，并通知界面刷新。 |
| [AgentTypes](../../Mindscape/Agent/AgentTypes.swift) | 请求/响应、错误、数据传输对象和 JSON 封装。 |
| [CLI](../../MindscapeCLI/Main.swift)、[AgentClient](../../MindscapeCLI/AgentClient.swift) | 将命令转换为 HTTP 请求；发现网关、健康检查以及按需请求启动应用。 |
| [AgentSkillInstaller](../../Mindscape/Agent/AgentSkillInstaller.swift)、[AgentOnboarding](../../Mindscape/Agent/AgentOnboarding.swift) | 安装 App 内置 Skill、检测目标 Agent 和展示一次性接入提示。 |
| [AgentSkill 资源](../../AgentSkill/SKILL.md) | 为外部 Agent 提供操作说明；同目录另含 OpenAPI、示例和版本文件，由 [project.yml](../../project.yml) 打包为应用资源。 |

## 调用链和生命周期

1. [RootView](../../Mindscape/Views/RootView.swift) 将 AppModel 交给共享的 AgentCoordinator，并在更新询问之后触发 Agent onboarding。
2. 新安装且没有启用设置时 `agent.enabled` 为 false。App 启动时若此前已启用、且没有 `--agent-start` 参数，则处于停止状态等待外部通知或连接测试；设置从关闭切换为开启时，`enabled` 的 `didSet` 会立即调用 `start()`。
3. Coordinator 创建使用当前 `app.store` 的 AgentService 和 AgentHTTPServer，先尝试端口 47821，失败时尝试系统分配的端口。服务只绑定 `127.0.0.1`。
4. 服务启动后尝试将 URL、进程等描述信息和访问凭据写入 `~/Library/Application Support/Mindscape/agent-gateway.json`，并将文件权限设为 `0600`。该文件含访问凭据，不应输出其内容。停止时尝试删除描述文件。
5. CLI 优先读取描述文件并请求健康检查；未连接时可通过分布式通知和 `open -g` 请求应用启动，再轮询网关；`--no-launch` 关闭自动启动。
6. 默认空闲 10 分钟停止，界面还支持 5、30 分钟及不自动关闭；后台每 30 秒检查一次。请求经校验并通过限流后更新活动时间。

## 安全和协议边界

- 每次新建服务时生成随机访问凭据；请求需提供匹配的 Bearer 认证。Host 仅接受当前端口的 `127.0.0.1` 或 `localhost`，带 Origin 的请求被拒绝。
- 每个连接只处理一个请求并关闭；支持 GET、POST、PATCH、DELETE、Content-Length，不支持 Transfer-Encoding。请求头上限 32 KB，请求体上限 1 MB；并发连接上限 8，每 10 秒最多 60 个已通过前置校验的请求。
- HTTP 服务工作队列经异步任务将业务处理转到 `@MainActor`；协调器等待响应最多 10 秒。业务成功和错误通常使用 `ok/data`、`ok/error` JSON 封装，OpenAPI 和 Skill 文本接口返回资源正文。
- [AgentService](../../Mindscape/Agent/AgentService.swift) 提供目录、导图、节点、批量、导入、导出和 Skill 安装路由；导图默认删除为移入回收站，永久删除需显式参数。节点移动拒绝循环，不能删除整图全部节点。批量修改先在内存中逐项执行，最多 500 项，全部通过后一次保存。
- Skill 说明要求 Agent 在破坏性操作前询问用户；网关路由本身没有额外的交互式确认步骤。文件导入和导出的路径约束详见[导入导出设计](import-export.md)。

## Skill 安装与 onboarding

- 打包资源包括 `SKILL.md`、`openapi.json`、`examples.md` 和 `VERSION`。安装器以用户目录中的 `.agents/skills/mindscape` 为公共位置，并处理 Claude Code、Codex、DSH、OpenCode 的目标位置或受管指令段。
- Codex 接入在其用户级 `AGENTS.md` 中插入或替换 Mindscape 标记段，保留其他内容；其他目标可能复制资源到相应目录。已有符号链接按安装器逻辑解析后写入。
- 一次性提示在测试期间跳过；如果检测到已有安装则标记为已询问。用户选择一键安装时，安装检测到的目标；若没有检测到目标，则安装公共资源。安装提示提供启用 Agent 的选项。
- 内置 [OpenAPI 定义](../../AgentSkill/openapi.json)描述网关接口；它与仓库 `openspec/` 中的开发规格用途不同。

## 验证依据与待确认项

- [AgentHTTPServerTests](../../MindscapeTests/AgentHTTPServerTests.swift) 覆盖鉴权、Host、Origin、大小、方法、限流和重启；[AgentServiceTests](../../MindscapeTests/AgentServiceTests.swift) 覆盖目录、导图、节点、批量和导出等。
- [AgentSkillInstallerTests](../../MindscapeTests/AgentSkillInstallerTests.swift) 使用临时目录验证资源打包、各目标安装、重复安装及已有指令保留。本次整理未运行 XCTest。
- **待验证**：服务持有启动时的 `DocumentStore`；App 切换数据目录后是否需要重启服务。当前切换实现见 [AppModel](../../Mindscape/App/AppModel.swift)。
- **待验证**：界面编辑有防抖保存，而服务从存储读取再写入并触发重建编辑器；两者短时间修改同一张图时的状态保留需要集成测试。
- **待验证**：更新导图时，服务先保存标题等字段，再校验并设置目录；目录参数失败时是否存在部分修改，需要通过测试确认期望。

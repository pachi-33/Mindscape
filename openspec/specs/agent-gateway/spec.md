# Agent 网关与 CLI

## Purpose

为本机 Agent 提供受控的思维导图访问方式，涵盖服务启停、请求鉴权、目录和导图操作、批量节点编辑与客户端接入，并复用应用的本地存储。

## Requirements

### Requirement: Agent 服务需要启用

应用 SHALL 以用户保存的 AI Agent 设置决定是否允许启动本地网关；未设置过时默认为关闭。

#### Scenario: 未启用时请求启动

- **WHEN** Agent 服务未启用且外部请求启动服务
- **THEN** 应用保持服务关闭，并引导用户前往 Agent 设置

#### Scenario: 已启用的应用等待调用

- **WHEN** 应用启动时 Agent 已启用且启动参数不要求启动服务
- **THEN** 网关处于停止状态，等待调用或连接测试

### Requirement: 限制网关监听和请求来源

网关 SHALL 仅绑定本机回环地址，并验证请求的 Host、访问凭据和浏览器来源。

#### Scenario: 缺少有效凭据

- **WHEN** 格式有效、Host 合法且不含 Origin 的请求未携带有效的 Bearer 凭据
- **THEN** 网关返回 HTTP 401，业务操作不执行

#### Scenario: 浏览器来源请求

- **WHEN** 请求带有 Origin 请求头
- **THEN** 网关返回 HTTP 403

#### Scenario: 非本机 Host

- **WHEN** 请求的 Host 不是当前监听端口的 `127.0.0.1` 或 `localhost`
- **THEN** 网关返回 HTTP 403

### Requirement: 服务空闲后停止

已启用的网关 SHALL 根据配置的空闲时长停止；默认空闲时长为 10 分钟。

#### Scenario: 空闲时长已到

- **WHEN** 网关已空闲达到配置时长且后台检查到该状态
- **THEN** 应用停止监听并尝试移除网关描述文件

#### Scenario: 不自动关闭

- **WHEN** 空闲时长设置为 0
- **THEN** 空闲检查不会因无请求而停止网关

### Requirement: 限制 HTTP 请求格式和资源消耗

网关 SHALL 检查受支持的方法、请求体格式和大小，并限制请求频率。

#### Scenario: 请求体过大

- **WHEN** 请求的 Content-Length 超过 1 MB
- **THEN** 网关返回 HTTP 413

#### Scenario: 非 JSON 请求体

- **WHEN** 通过 Host、Origin 和 Bearer 认证校验的请求带有非空请求体，且 Content-Type 不以 `application/json` 开头
- **THEN** 网关返回 HTTP 415

#### Scenario: 请求过于频繁

- **WHEN** 有效请求超过 10 秒内 60 次的限制
- **THEN** 超限请求返回 HTTP 429

### Requirement: 管理目录和导图

网关 SHALL 提供目录及导图的查询和修改接口，并在成功修改后通知应用刷新数据。

#### Scenario: 创建导图

- **WHEN** 收到有效的创建导图请求
- **THEN** 服务保存新导图并返回其 ID、节点和其他导图信息

#### Scenario: 默认删除导图

- **WHEN** 请求删除已存在的导图且未指定永久删除
- **THEN** 导图被移入回收站

### Requirement: 编辑节点并避免结构循环

网关 SHALL 支持新增、更新、移动和删除节点，并拒绝会导致节点循环或删除导图全部节点的操作。

#### Scenario: 移动节点到其子树

- **WHEN** 请求将一个节点移动到自身或其后代节点之下
- **THEN** 服务返回 HTTP 409，拒绝该移动

#### Scenario: 删除全部节点

- **WHEN** 删除某节点及其子树会移除整张导图的全部节点
- **THEN** 服务返回 HTTP 409，拒绝该删除

### Requirement: 批量修改节点

网关 SHALL 支持一次处理 1 至 500 个节点操作，并在操作全部通过后保存导图。

#### Scenario: 有效批量请求

- **WHEN** 单次请求包含 1 至 500 个有效节点操作
- **THEN** 服务按顺序应用操作，保存一次并返回更新后的导图

#### Scenario: 批量操作中存在无效项

- **WHEN** 处理批量操作时某一项校验失败
- **THEN** 服务返回错误且不执行该批次的最终保存

### Requirement: 安装应用提供的 Agent Skill

应用 SHALL 支持将内置的 Mindscape Skill 资源安装到受支持的本机 Agent 位置。

#### Scenario: 安装 Codex 接入

- **WHEN** 用户选择安装 Codex 的 Mindscape Skill 且资源可用
- **THEN** 安装器写入公共 Skill 资源并在 Codex 的指令文件中更新 Mindscape 受管段落

#### Scenario: 已有用户指令

- **WHEN** 目标指令文件中已有不属于 Mindscape 受管段落的内容
- **THEN** 安装器保留这些内容并插入或更新 Mindscape 段落

### Requirement: CLI 连接本地网关

CLI SHALL 通过网关描述文件发现并验证运行中的本地服务，在允许启动应用时可请求启动网关。

#### Scenario: 网关可用

- **WHEN** CLI 读取到可用的网关信息且健康检查成功
- **THEN** CLI 使用该网关执行请求

#### Scenario: 禁止启动且网关不可用

- **WHEN** 用户使用 `--no-launch` 且找不到可用网关
- **THEN** CLI 报告网关不可用

# 应用生命周期与更新：现状设计

## 职责与边界

应用入口和全局模型负责窗口、当前文档库、失活/退出保存以及首启提示协调。更新子系统负责偏好、检查发布版本、展示状态、下载安装包和可用时的校验；安装包的实际替换由用户和系统完成。

| 类型 | 职责 |
|---|---|
| [MindscapeApp](../../Mindscape/App/MindscapeApp.swift) | 创建主窗口、设置场景、菜单栏入口和共享 AppModel |
| [AppModel](../../Mindscape/App/AppModel.swift) | 打开存储、回退并提示、维护当前编辑器，在失活/退出时发起保存 |
| [RootView](../../Mindscape/Views/RootView.swift) | 根据当前编辑器选择工作区或空状态，连接 Agent 和首启提示流程 |
| [UpdateChecker](../../Mindscape/Support/UpdateChecker.swift) | 维护更新偏好、通道、检查/下载状态、横幅和校验结果 |
| [GitHubUpdateService](../../Mindscape/Support/GitHubUpdateService.swift) | 查询 GitHub Releases API，失败时依次尝试 Atom 和发布页重定向 |
| [FileDownloadOperation / FileChecksum](../../Mindscape/Support/FileDownloadOperation.swift) | 使用 URLSession 下载文件、报告进度，并提供 SHA-256 计算和摘要解析 |
| [UpdateWindow](../../Mindscape/Views/UpdateWindow.swift) | 展示更新状态，提供打开安装包、保存并退出等动作 |

## 生命周期

`AppModel` 初始化时读取外观偏好、尝试创建 `DocumentStore`、加载目录和文档，并监听应用失活与终止通知。自定义目录不可用时回退默认目录；没有可用磁盘库且内存库创建成功时使用内存库并提示。`RootView` 稳定后依次处理更新授权与 Agent 引导，再结束首次提示协调。更新可用且横幅未隐藏时，工作区覆盖层显示横幅；横幅也会自动隐藏。

`saveAndQuitForUpdate()` 在打开下载文件前调用当前编辑器的 `saveNow()`；只有系统成功接收打开文件请求时才安排退出。`saveNow()` 目前不向调用方返回保存结果，因此这个调用本身不能证明数据已成功写入磁盘。

## 更新检查

- 自动检查初始默认关闭；第一次需要询问时通过 `UserDefaults` 保存决定。
- 启用后启动时安排一次检查；常驻期间周期性判断，上次成功检查达到 24 小时时再检查。没有成功检查时间时，每小时心跳也会尝试检查。手动检查不受该节流限制，但已有检查或下载正在进行时不会并发发起。
- 安装版本含预发布标识时使用包含预发布版本的查询；稳定版使用正式版本通道。服务对 API、Atom、重定向返回结果做归一化，并使用 ETag / 缓存处理未修改响应。
- 手动失败转为可见的失败状态；后台失败保持已有可用更新状态或回到空闲。跳过版本和手动关闭横幅会写入偏好。

## 下载与校验

优先选择 DMG，否则选择 ZIP。下载完成后，如对应校验地址返回可解析的摘要，后台计算文件 SHA-256：匹配则标记已验证，不匹配或读取失败则尝试删除下载文件并报告失败。没有取得有效摘要时状态为 `notProvided`，下载仍可完成；这也包括校验地址访问失败的情况。此处记录的是当前行为，不能将所有下载描述为均已校验。

GitHub API 返回的附件 URL 会校验为指定仓库下的 HTTPS 下载路径。更新服务和 Agent 本地网关是独立子系统；前者可能访问 GitHub，后者只监听本机。

## 现有测试与待确认项

[UpdateCheckerTests.swift](../../MindscapeTests/UpdateCheckerTests.swift) 覆盖默认偏好、首次询问、启动检查、自动节流、手动检查、下载校验等；[UpdateServiceTests.swift](../../MindscapeTests/UpdateServiceTests.swift) 覆盖版本解析、发布信息解析、回退、地址校验和摘要计算。上述测试存在于仓库，本次基线建立不等于已完成运行验证。

- 校验文件缺失或获取失败时允许继续，是否需要更严格的策略属于后续产品与安全决策。
- 当前编辑器保存失败没有返回给 `saveAndQuitForUpdate()`，保存和退出的失败反馈值得单独评估。
- 当前测试和命令不等同于实际安装包替换的端到端验证。

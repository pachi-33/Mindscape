# OpenSpec 开发环境

本项目使用 OpenSpec 管理开发变更。当前项目文件由 OpenSpec **2.1.1** 生成；OpenSpec 是开发工具，不会打包进 Mindscape 应用。

## 文件位置

- `openspec/config.yaml`：项目的 OpenSpec 配置、语言和精简技术背景。
- `openspec/specs/`：已建立的能力规格和可验证场景。
- `openspec/changes/`：进行中的变更及归档记录。
- `.agents/skills/openspec-*/`：供 Codex 使用的项目级 OpenSpec Skill。

当前代码的总体架构与各子系统设计见[现状架构基线](architecture/overview.md)。

仓库包含核心及扩展工作流。初次拉取或更新 Skill 后，如果 Codex 未显示新增 Skill，请重新加载或重启会话。

## 安装 CLI

项目中的 Skill 需要 `openspec` 命令。macOS 和 Linux 可以使用官方独立安装脚本，并指定与项目一致的版本：

```bash
curl -fsSL https://raw.githubusercontent.com/Fission-AI/OpenSpec/v2.1.1/scripts/binary/install.sh | OPENSPEC_VERSION=v2.1.1 sh
openspec --version
```

脚本默认安装到 `~/.local/bin`；该目录需要位于 `PATH`。其他安装方式见 [OpenSpec 官方安装文档](https://github.com/Fission-AI/OpenSpec/blob/v2.1.1/docs/installation.md)。

OpenSpec CLI 默认启用匿名使用统计。若不希望发送，可在使用前执行：

```bash
OPENSPEC_TELEMETRY=0 openspec config set telemetry.enabled false
```

这项设置作用于当前用户的 OpenSpec CLI，不影响 Mindscape 应用。

## 常用操作

在 Codex 中可选择或调用以下 Skill：

- `$openspec-explore`：讨论和澄清问题。
- `$openspec-propose`：创建变更提案及配套文档。
- `$openspec-apply-change`：按变更文档实施。
- `$openspec-verify-change`：检查实现与变更文档是否一致。
- `$openspec-archive-change`：归档已完成的变更。

也可以在项目根目录通过 CLI 查看和检查：

```bash
openspec list
openspec list --specs
openspec validate --all --strict
```

规格和变更都为空时，校验会显示 `No items found to validate`。OpenSpec 的结构校验不能替代项目测试。

## 更新项目级 Skill

OpenSpec 的工作流选择保存在当前用户的全局配置中。仓库包含完整的核心和扩展工作流；在运行 `openspec update` 刷新这些项目文件前，若要保留全部工作流，先确认本机选中了所需工作流。可运行 `openspec config profile` 进行选择，再使用 `openspec update --dry-run` 查看预期变更。

更新这些全局设置也会影响本机其他 OpenSpec 项目的后续 Skill 更新；直接使用项目中的 Skill 不需要调整全局配置。

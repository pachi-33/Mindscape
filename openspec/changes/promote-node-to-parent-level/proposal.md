# Proposal
## Why
子节点拖到父节点所在层级的空隙时会回弹，用户无法同时调整层级与顺序。
## What Changes
思维导图与左右逻辑图支持把单个子节点及其子树提升一级，插入父节点所在兄弟序列的任意空隙与两端。
## Capabilities
### Modified Capabilities
- `canvas-interaction` 增加提升层级的插入线及落点提交。
- `mind-map-editing` 支持原子地迁移并按指定相对位置插入。
## Impact
涉及画布、编辑器、撤销及画布鼠标事件测试。

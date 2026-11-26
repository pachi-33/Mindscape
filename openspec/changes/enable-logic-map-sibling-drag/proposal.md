# Proposal

## Why

在左、右逻辑图中，将节点拖到兄弟之间的空隙会回弹。用户需要在保留层级的同时调整阅读顺序。

## What Changes

左右逻辑图支持单选节点拖到同级空隙排序，悬停时显示插入线，松手时按最终位置提交。

## Capabilities

### Modified Capabilities

- `canvas-interaction` 增加左右逻辑图的同级插入手势。

## Impact

变更涉及 AppKit 画布落点判定及鼠标事件测试。沿用现有编辑器排序、持久化及撤销机制。

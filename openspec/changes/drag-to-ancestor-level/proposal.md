# Proposal

## Why

beta.3 只查找原父节点和祖父节点的子节点空隙。更深的节点拖到祖父节点所在层级时，无法在指定位置落下。

## What Changes

在思维导图与左右逻辑图中，可将单个节点拖到任一祖先所在的可见兄弟序列中，插在两个节点之间或序列首尾。

## Capabilities

### Modified Capabilities

- `canvas-interaction` 支持跨多级插入。
- `mind-map-editing` 支持将整棵子树插入头部节点序列。

## Impact

变更涉及画布落点、编辑器事务和跨层鼠标事件测试。

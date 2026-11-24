# 画布与布局现状设计

本文记录 0.7.0 代码基线中画布的职责、调用关系与约束；用户可观察行为见 [画布与布局规格](../../openspec/specs/canvas-interaction/spec.md)。内容依据源码与现有测试静态整理，不代表本次已运行测试或完成所有手动交互验证。

## 职责与边界

画布负责将导图节点、连线和交互反馈显示在可平移缩放的视口中，并将选择、编辑、拖动等用户操作交给 `MapEditor`。节点结构、持久化和撤销历史由模型、编辑器及存储层负责；画布不直接执行 SQL。

| 部件 | 现有职责 |
|---|---|
| [WorkspaceView / MapCanvasRepresentable](../../Mindscape/Views/WorkspaceView.swift) | 在 SwiftUI 工作区中创建、更新 AppKit 画布，传入编辑器、主题和搜索结果。 |
| [CanvasBridge](../../Mindscape/Canvas/CanvasBridge.swift) | 在 SwiftUI 控件和 `MindCanvasView` 之间转发缩放、适配、定位和聚焦请求；画布尚未附着时暂存部分请求。 |
| [MindCanvasView](../../Mindscape/Canvas/MindCanvasView.swift) | 持有相机和交互状态，管理布局缓存、动画、鼠标键盘事件、就地编辑及无障碍元素。 |
| [LayoutEngine](../../Mindscape/Canvas/LayoutEngine.swift) | 从 `MindMap` 构造 `LayoutResult`，计算节点矩形、深度、子节点索引、绘制顺序和边界。 |
| [NodeMeasurer](../../Mindscape/Canvas/NodeMeasurer.swift) | 测量节点与文本；测量使用 AppKit 字体和文本几何。 |
| [MapRenderer](../../Mindscape/Canvas/MapRenderer.swift) | 根据布局、主题和选择状态绘制背景、节点、连线及相关视觉元素。 |
| [FreeLayoutSnap](../../Mindscape/Canvas/FreeLayoutSnap.swift) / [CanvasMotion](../../Mindscape/Canvas/CanvasMotion.swift) | 分别计算自由布局的对齐吸附和逐帧动画策略。 |

## 状态与数据流

1. `MapEditor` 持有导图与选区；操作修改模型后递增 `revision`。`MapCanvasRepresentable` 将当前编辑器和版本交给画布。
2. `MindCanvasView` 在需要时调用 `LayoutEngine.layout`；结果以节点 UUID 对应画布世界坐标中的矩形。多头部导图在自动布局中按树分别计算并排列，自由布局会尊重已记录的节点位置。
3. `MindCanvasView` 使用 `CanvasCamera` 在世界坐标与视图坐标间转换；缩放范围是 0.15 至 3.5。`MapRenderer` 使用布局与主题绘图，导出绘制也复用布局和渲染逻辑。
4. 选择、文字或结构操作通过 `MapEditor` 更新；编辑器负责后续保存及撤销。画布仅保留拖拽偏移、搜索高亮、焦点、动画帧等视图状态。

## 布局与交互细节

- [MapLayout](../../Mindscape/Models/MapLayout.swift) 定义八个布局值。思维导图有 `remember` 与 `balanced` 两种一级分支模式；平衡分侧使用完全展开时的分支高度。旧数据缺少排列模式时按 `remember` 处理。
- 自动布局先按父子关系和 `order` 建立索引，计算各节点尺寸，再按布局类型放置。布局构造对重复 ID 和无法从头部到达的节点有防御性处理；递归辅助计算也有限深，损坏数据的所有表现仍应以具体测试为准。
- 思维导图拖动使用当前视觉帧命中目标，目标外围有屏幕空间磁吸范围，并对已锁定目标加入滞留；预览基于编辑器对落点的非破坏性模拟。正常同级拖动可排序，一级分支可换侧。
- 自由布局普通拖动更新位置；按 Option 拖至合法目标时可变更父子关系并保留落点。对齐比较节点外框的边与中线，多选以选中组的外接矩形参与吸附。
- 普通滚轮平移，Command 加滚轮或捏合手势缩放。选中节点可通过双击或键盘进入 `NSTextView` 编辑；输入法标记文本先触发编辑框尺寸调整，再同步到编辑模型。提交空白文字时使用占位文字，取消编辑恢复原文字。
- 节点和折叠控件的命中测试在帧动画期间使用 `displayFrames`；框选当前使用布局结果中的帧。折叠后隐藏的子孙节点不产生可见布局矩形。

## 动画与无障碍

`CanvasMotion` 读取系统“减弱动态效果”设置；节点超过 800 时关闭逐帧落位动画，超过 300 时使用较低帧率。动画期间还会维护折叠残影和节点透明度状态。

画布将有布局矩形的节点作为辅助技术可访问元素暴露。元素标签包含节点显示文字和直接子节点数量，并根据状态附加折叠、备注和可识别图标信息；自定义操作支持选中及折叠切换。实现见 [MindCanvasAccessibility.swift](../../Mindscape/Canvas/MindCanvasAccessibility.swift) 和 `MindCanvasView.accessibilityChildren()`。

## 验证依据与边界

- [MindscapeCoreTests.swift](../../MindscapeTests/MindscapeCoreTests.swift) 包含八种布局、多头部、缩放桥接、普通同级拖动换序、一级分支换侧、磁吸范围、自由布局 Option 拖动及多选等测试。
- 同一测试文件的 `testMarkedTextKeepsNodeInSync`、`testComposingTextDoesNotWrapAndBounce`、`testCanvasAccessibilityTree` 与 `testCanvasMotionPolicy` 对输入法模拟、辅助元素和动效策略提供回归依据。
- 规格覆盖主要交互而非所有几何常量。触控板手势、真实输入法候选窗、VoiceOver 和大图性能仍需在实际 macOS 界面中补充验证；本次没有运行 XCTest。

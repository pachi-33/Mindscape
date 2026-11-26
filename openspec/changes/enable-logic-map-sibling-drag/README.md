# enable-logic-map-sibling-drag

在 main 的画布鼠标事件测试中，左、右逻辑图把 D 拖到 A、B 的空隙时均未显示插入线，松手后仍为 A、B、C、D。MindCanvasView 的悬停预览和松手提交都仅在 .mindMap 布局解析同级插入位置。验收时左右布局均应得到 A、D、B、C，并覆盖首尾插入、其他父节点空隙、子树保留及撤销重做。

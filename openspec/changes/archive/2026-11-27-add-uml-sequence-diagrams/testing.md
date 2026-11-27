# 测试设计与执行记录

| 验收项 | 路径与判据 |
| --- | --- |
| 新建与编辑 | 走 macOS 用户界面上的新建入口，创建图元、选择收发双方、插入嵌套片段，核对选中态、样式、保存后重开。 |
| 语义与诊断 | 自动测试消息种类、自调用、嵌套、激活、错误行；覆盖空白和旧文档。 |
| 保存与共享 | 覆盖草稿、撤销／重做、SQLite 重开、JSON 往返、错误文档类型、不可渲染草稿。 |
| 端到端 | 隔离数据库；图形界面新建空白、分步完成全图；实际 HTTP 回读并导出，独立打开成图。 |
| 图像 | 检查 PDF 实际绘制内容、标签、方向、框和长文本；独立审阅读取渲染图。 |
| 算法核对 | 对照 v0.5.17 固定提交，独立检查四级角色、当前/下一槽、前向候选与回传共识、proxy/output、异步深度、结果及释放、空闲条件。 |
| 回归 | 运行完整 XCTest 和全部 OpenSpec 的严格校验。修复发现的问题后复测并记录。 |

执行结果及交付文件见下方验收记录。

## 执行环境

2026-11-27 在 Apple Silicon macOS 上使用 Xcode 构建。界面和 HTTP 端到端运行使用独立 bundle identifier、SQLite 库及网关描述文件位置。正式源码另外直接构建。样例只写入本次测试库，导出后可在其他 Mindscape 库中导入。

## 测试方法

- 新建、命名、选择端点、绘图、切换片段范围与修改主题均经过真实 macOS 窗口。自动化通过系统辅助功能点按图形控件并在名称、守卫、消息或备注字段输入可见文字。依据独立的操作清单核对数据。网关只负责回读和导出这张图。
- 接口的增量写入另行测试。在独立文档使用 8 次 PATCH 并逐次 GET，包含未完成片段的草稿。JSON 导出再导入取得新 ID，正文一致。
- 可复查的回归用例在 MindscapeTests 的 Sequence 测试类中。项目根运行 `xcodegen generate`，再运行 `xcodebuild -scheme Mindscape -destination 'platform=macOS' -parallel-testing-enabled NO test`。在有个人数据的开发机，端到端验收使用独立测试库和网关。

## 首轮独立语义验收

独立 Sol 审阅者未参与实现或样例编写，先阅读实际导出的整张图并回述协议，然后打开固定提交的 Python 文件逐项检查。首次审阅纠正了两处文字。末级在 launch 时记录事件并入 FIFO，真正发送前等待取出的 q_event。bootstrap 从 good 排除本地 abort，并将**所有**本地 abort RID 并入 bad。修订图另明确了分开投递的三类消息与共享张量通道的按类型暂存。

| 从成图重建的行为 | 核对范围（固定提交中的行） |
| --- | --- |
| R0 获取外部请求，后续各级逐跳接收；候选和 proxy 前向传播 | request_receiver.py 104–149，scheduler_pp_mixin.py 242–279、330–349、1087–1098 |
| L=4+D、n=(i+1)%L、f=(i+4)%L；先处理当前槽，再取指定历史槽 | scheduler_pp_mixin.py 228–240、559–579 |
| bootstrap good 交集、bad 并集与 abort；transfer 已结束 RID 交集 | 823–888、1397–1408 |
| D>0 在 launch 前交换 output，D=0 在其后；R3 从 FIFO 取数并等待对应事件，其他级转发旧值 | 275–300、940–963、1174–1316 |
| 两类共识独立守卫、顺序接收与等待；下一槽结果处理后释放，最后发当前请求与 proxy | 300–355、890–933 |
| 一轮无批且 inflight 为空才 on_idle；XPU 奇数级 output 先收后发；proxy 与 output 在共享通道按类型匹配 | 355–359、1029–1108、1209–1276 |

首轮修正经源码复核，作为最终界面绘图的语义基准。上游版本固定为 SGLang v0.5.17。[调度函数](https://github.com/sgl-project/sglang/blob/29481685462732237d80d86076d6563e1f658102/python/sglang/srt/managers/scheduler_pp_mixin.py#L178-L359)

## 最终图形化验收

1. 从真实 macOS 窗口的侧栏“+”菜单新建空白时序图并命名。通过 72 次图形操作加入 4 条生命线、33 条消息、9 条备注及 13 个组合片段（2 个 loop、11 个 opt），并逐一离开这 13 个片段。文字输入仅用于名称、消息、备注和条件。图的正文最终包含 68 个有序事件。
2. 切换到“商务蓝”、保存、退出应用，再用同一测试库启动。窗口恢复这份时序图，HTTP 回读确认主题为 `corporate`。逐项核对参与者、箭头种类、双方、标签、守卫、嵌套和顺序，全部匹配。切回“纸白”后导出 JSON、PNG 和单页矢量 PDF。再次冷启动，四个参与者完整出现在首屏；点选 R1 后显示选中高亮和对应的属性表单。
3. 在另一份临时空白图中，通过画布点选同一条生命线建立返回自调用，通过属性面板创建 alt/else 和激活段；随后对参与者改名、上移、撤销并重做，回读核对两次顺序及生命线引用。
4. 由未参与实现或绘图的独立 Sol 审阅者在未读源码的情况下，依次阅读从 PDF 渲染的五段画面并复述协议，再对照固定提交的调度及接收实现。其结论为普通 CUDA 分离式 prefill 的 PP4 调度一致。复核覆盖槽位、流水级间传递、两类共识的独立守卫、CUDA/XPU 输出交换顺序、三个事件等待和空闲处理。最终颜色修订后的五段图像也经复核，单页提取文本与语义审阅版逐字节一致。[调度与通信辅助函数](https://github.com/sgl-project/sglang/blob/29481685462732237d80d86076d6563e1f658102/python/sglang/srt/managers/scheduler_pp_mixin.py) · [请求接收器](https://github.com/sgl-project/sglang/blob/29481685462732237d80d86076d6563e1f658102/python/sglang/srt/managers/scheduler_components/request_receiver.py)

样例 PDF 为一页，1075 × 3833 pt，SHA-256 为 `1f41f2b925873d9821d6f06daae7da9a00e626f2d72061c287e31b88ad8e9247`。两处较长的方法名在词中折行，详细视图以一个自调用及注释概括 output 交换。图侧重 scheduler 之间的协议，未展开每个 GPU stream 的内部依赖；验收采用源码核对，未运行四卡性能测试。仓库 `docs/examples/sglang-pp4/` 中提供已审阅的 PDF、可编辑 JSON 和真实窗口截图。

### 图形编辑回归结果

最终应用宿主全量运行 186 项 XCTest，零失败。28 项时序图测试分布于 SequenceDiagramCoreTests.swift、SequenceInterchangeTests.swift、SequenceCanvasInteractionTests.swift、SequenceGraphicViewportTests.swift 和 SequenceInspectorBindingTests.swift，覆盖以下路径。

| 风险 | 核验结果 |
| --- | --- |
| 图元改名后连错对象，移动片段后出现交叉 | 检查稳定的生命线 ID、嵌套与分支配对、激活段移动及删除；拒绝的修改没有写入，成功修改可单步撤销。 |
| 屏幕点按或拖动落到相邻元素 | AppKit 窗口中核对头部、生命线、双击、消息折线、片段、备注、激活条以及滚动放大后的命中与拖拽位置。 |
| 离开嵌套条件时崩溃，关闭的表单覆盖新表单 | 首次完整界面走查在退出内层 opt 时触发 SwiftUI 对空 binding 的强制解包。已改为带会话标识的表单绑定；额外 2 项用例持有旧文本框和 Picker，验证关闭或打开另一表单后的延迟读取和写入。 |
| 导出颜色与文件主题有偏差，或导出包含选框 | 屏幕与导出共用 MapTheme；PNG 在显式 sRGB 位图上下文绘制。像素采样核对主题填色、边缘和背景，以及有无选框的差异。 |
| PDF 网格比画布深、初始缩放使生命线标题离开视口 | PDF 改用带主题颜色的矢量网格；在纸白、蓝图主题上用 2× 光栅化测试核对网格点和背景。实物 PP4 的 PDF 与 PNG 网格点 sRGB 都为 (242, 238, 233)。长图首次布局以左上角定位，回归测试验证首屏四张卡片完整、滚动中修改图或调整窗口宽度后保留当前阅读位置。 |

OpenSpec 归档前后均运行 `openspec validate --all --strict`，时序图能力包含 6 项正式需求。工作树编译和隔离测试构建均成功。

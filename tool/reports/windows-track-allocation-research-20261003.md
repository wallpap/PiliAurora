# Windows 轨道分配拒绝研究（2026-10-03）

> 阶段说明：第 1–11 节保留本代理研究阶段的源码快照、验证结果和建议。“未复现／待补／预计失败”属于当时状态，不代表主代理交叉验证后的最新状态。2026-10-03 的主代理红灯结果及当时拟修复方案见第 12 节；最新 green 与 analyze 通过结果见第 13 节，已由主代理提供。

## 1. 范围、版本与结论

仅研究轨道分配及拒绝。未修改实现、测试或依赖，未执行 Git 写操作；未启动真实播放器；未研究或修复原生退出。唯一新增的仓库文档是本文件。

- 仓库：`E:/Code/project/PiliAurora`。
- 研究开始时分支：`codex/windows-playback-experiments-20261003`。
- 研究开始时 HEAD：`68e8bd11ec23a47b3db68a8bc69caa5613bbb1b6`；初始工作区干净。行号以本次读取的工作区文件为准。
- 锁定依赖：`canvas_danmaku 0.2.6`，提交 `275046d8647a6a26cba1d0dadb9e28688cb3dbf1`。[LOCK:232–240]
- 本地依赖缓存 HEAD 与锁定提交一致，缓存工作区干净；不是对上游最新 main 的评估。已查阅该固定提交的一手源码。

### 结论先行

1. **已确认：** `rejectedByTrack` 是普通弹幕在资源检查后仍未选到轨道的累计次数。它不是总拒绝数，不含零轨道提前返回，也不是发生重叠的次数。[R:202–213,250–298]
2. **已确认：** 滚动与静态使用两个独立池；顶部与底部共享同一个静态池。海量模式只为滚动路径提供强制叠加，不自动扩大静态容量。当前播放基准开启海量模式，但未开启静态转滚动。[R:72–74,260–315; B:127; UO:60–77]
3. **已确认：** 正常滚动的追赶判据具有合理的几何依据；未发现足以把它判定为“过度拒绝 bug”的证据。`nextWidth` 未直接使用不是充分的缺陷证据，因为调用方已将宽度纳入速度计算。[R:158–160,277–286; T:39–49]
4. **已确认：** 三份短样本的轨道拒绝差分均为 187；与样本的总拒绝及外层拒绝字段不能对账。不能把累计 359 当作两秒测量期的轨道拒绝，也不能把 243 条总拒绝全归为轨道问题。见第 4 节。
5. **研究阶段状态：源代码已确认、运行复现待补。** 后续主代理已复现 hideScroll 两个失败场景，见第 12 节；静态 selfSend 的策略仍未确认。研究阶段结论如下： 静态转滚动路径未检查目标类型的 `hideScroll`，与锁定上游的转换条件不一致；静态 selfSend 的满轨兜底也与上游不同。这两项应先补小型测试并明确策略，不应用“降低所有轨道拒绝”掩盖语义差异。[R:203–205,261–293; US:220–228,247–254]
6. **建议：** 先完善拒绝分类与短离线测试，再考虑静态满轨预判。不要先扩容、开启叠加或放宽追赶条件。

## 2. 证据索引

下文 `[ID:行号]` 均指以下绝对路径。数字区间包含首尾行。

| ID | 文件 |
| --- | --- |
| R | `E:/Code/project/PiliAurora/lib/pages/danmaku/windows_renderer.dart` |
| T | `E:/Code/project/PiliAurora/lib/pages/danmaku/trajectory.dart` |
| RC | `E:/Code/project/PiliAurora/lib/pages/danmaku/raster_cache.dart` |
| S | `E:/Code/project/PiliAurora/lib/pages/danmaku/windows_screen.dart` |
| V | `E:/Code/project/PiliAurora/lib/pages/danmaku/view.dart` |
| C | `E:/Code/project/PiliAurora/lib/pages/danmaku/controller.dart` |
| O | `E:/Code/project/PiliAurora/lib/plugin/pl_player/utils/danmaku_options.dart` |
| B | `E:/Code/project/PiliAurora/tool/danmaku_playback_benchmark.dart` |
| RT | `E:/Code/project/PiliAurora/test/pages/danmaku/windows_renderer_test.dart` |
| TT | `E:/Code/project/PiliAurora/test/pages/danmaku/trajectory_test.dart` |
| ET | `E:/Code/project/PiliAurora/test/pages/danmaku/windows_experiment_test.dart` |
| GT | `E:/Code/project/PiliAurora/test/pages/danmaku/render_guard_test.dart` |
| LOCK | `E:/Code/project/PiliAurora/pubspec.lock` |
| REPORT | `E:/Code/project/PiliAurora/tool/reports/windows-playback-experiment-20261003.md` |
| TELEMETRY | `E:/Code/project/PiliAurora/tool/reports/windows-playback-telemetry-semantics-20261003.md` |
| US | `E:/Pub/Cache/git/canvas_danmaku-275046d8647a6a26cba1d0dadb9e28688cb3dbf1/lib/danmaku_screen.dart` |
| UO | `E:/Pub/Cache/git/canvas_danmaku-275046d8647a6a26cba1d0dadb9e28688cb3dbf1/lib/models/danmaku_option.dart` |

上游网页核对使用固定提交的 `lib/danmaku_screen.dart`，不是可变分支。上游算法和选项的引用以本地固定源码行号为准；网页解析的行号不用于本报告。

## 3. 实际调用链、容量与拒绝语义

### 3.1 生产路径不等于基准路径

- Windows 默认采用预处理 renderer；`WindowsDanmakuScreen` 负责创建、配置和 ticker 驱动。ticker 将 elapsed 差值传给 `advance`，不是 paint 次数决定弹幕寿命。[V:44–47,267–283; S:45–49,63–84,90–114]
- 生产入场先检查轨道数，再按百毫秒时间桶取数据，执行数量限制、权重过滤、采样、高级弹幕限制与转换，最后调用 `addDanmaku`。这些在 renderer 外跳过的元素不会成为 `rejectedByTrack`。[V:121–133,135–194]
- 生产海量模式、静态转换、显示区域、行高、隐藏选项来自用户配置，不能用基准的固定选项代表所有用户配置。[O:26–45]
- 基准的 `_admitUntil` 使用游标消费所有已到期元素；游标在 add 前已递增。普通容量拒绝不是排队等待，当前基准不会在下一帧自动重试同一元素。[B:419–449]
- 生产同一百毫秒桶由 `latestAddedPosition` 阻止重复处理，renderer 自身也没有拒绝重试队列。新增重试会改变时序、显示密度及产品语义，不属于无行为变化优化。[V:128–133; R:202–320]
- 在线源缓存还在 renderer 之前执行桶数量限制、合并和过滤。源元素数不等于 add 尝试数，更不等于轨道拒绝数。[C:83–142]

### 3.2 轨道数量

逻辑轨道数为：

```text
N = max(0, floor(viewHeight * area / measuredTrackHeight)
           - (safeArea && area == 1 ? 1 : 0))
```

`measuredTrackHeight` 来自文本“弹幕”的 `TextPainter`，使用 option 的 fontSize 与 lineHeight。空尺寸或非正轨高产生零轨道。滚动池和静态池均有 N 个槽位。[R:128–156]

这是逻辑尺寸计算，不应把 DPR 直接乘入 N。DPR 影响 raster 的像素尺寸和内存保护，可能让内容在到达轨道分配前被拒绝。[R:128–156; RC:101–120]

现有测试已经确认：`Size(320,120)`、fontSize 20、area 0.3、safeArea false 得到 1 条轨道。后续最小场景可复用这组条件，不必猜测字体测量值。[RT:10–11,141–146]

**正常容量约束：** 减小 area、增加 fontSize/lineHeight、缩小视口或预留字幕空间都会减少 N。拒绝随之增多不自动构成 bug。当前实现保留字幕一行的公式与锁定上游一致。[R:128–156; US:474–480]

### 3.3 滚动、静态与强制兜底

| 路径 | 选轨规则 | 没有合格轨道时 |
| --- | --- | --- |
| 滚动 | 从索引 0 开始，取第一个空轨或尾项允许跟随的轨道 | selfSend 固定叠加到第 0 轨；否则 massiveMode 随机叠加；两者都没有才拒绝 |
| 顶部静态 | 从索引 0 开始找空静态槽 | static2Scroll 为真则尝试滚动，否则拒绝 |
| 底部静态 | 从最后一个索引开始找空静态槽 | 同上；顶部与底部竞争同一静态池 |
| 超宽静态 | static2Scroll 为真且宽度大于视口时转滚动，即使已有空静态槽 | 使用滚动规则，不等于单独设置静态轨道容量 |
| 高级弹幕 | 通过特殊 raster 和内存检查后进入 special 列表 | 不执行普通选轨；但仍会受前置零轨道判断影响 |

证据：[R:202–249,259–315]。随机源固定为 `Random(0)`，但随机兜底只影响叠加落点，不代表正常轨道是否可用。[R:77,291–293]

滚动与静态可以位于相同 y；这种跨池重叠会由 `_recordOverlap` 标记。`canPaintDirectly` 是绘制合成安全状态，不是“还剩多少轨道”。[R:99,188–199,308–315,563–584]

### 3.4 各类计数究竟表示什么

普通 add 的顺序是：前置条件 → 文本布局与单项保护 → 活动账面内存 → 分配轨道 → 栅格化/clone → 接受。[R:202–213,250–319]

| 情形 | add 返回 | 当前计数行为 |
| --- | --- | --- |
| disposed、隐藏源类型、零轨道、非正 duration/staticDuration | false | 通常无原因计数；若同一调用同时达到活动数量上限，仍会增加 active limit 计数 |
| 活动条数达到 600 | false | `rejectedByActiveItemLimit += 1` |
| 普通 raster 布局尺寸/预算保护未通过，或高级弹幕保护未通过 | false | `rejectedByRaster += 1` |
| 活动图片账面预算不够 | false | `rejectedByMemoryBudget += 1`；默认预算 96 MiB |
| 普通路径未选到静态或滚动轨道，且没有适用兜底 | false | `rejectedByTrack += 1` |
| 分配完成后 `rasters.rasterize(...)` 返回 null | false | 未增加上述四类计数；源码存在此分支，不代表本次样本走过它 |
| configure 缩轨、隐藏或重栅格失败导致旧活动项被丢弃 | 不是 add 调用 | 不属于新增 add 的轨道拒绝计数 |

证据：[R:54–64,93–96,202–298,299–300,463–506; RC:65–85,88–120]。

注意：前置 OR 判断并非严格按首个失败条件归因。active limit 的累加取决于活动数是否达上限，可能伴随 hidden/disposed 等条件。四种原因计数因此既不覆盖所有 false，也不应被解释成全部入场策略的分类。[R:202–213]

计数以 renderer 实例累计；`clear` 不重置计数，也不重置时钟。对同一实例求测量期差分，重建实例或基线路径则重新建基线。[R:87–96,101–125,627–647]

内存账面量与轨道容量是两个独立门槛。扩大 Cache 或 active budget 不会直接增加 N；活动 clone 与缓存图像可能共享 backing，不能把账面字节和当作物理占用。[R:128–156,255–257,305; REPORT:74]

## 4. 已保存样本：可确认数值与对账限制

只读取以下原始 JSON 的数值白名单字段；未导出媒体位置路径、弹幕正文、身份标识或凭据：

- `E:/Code/project/PiliAurora/build/playback-20261003-smoke/smoke.json`
- `E:/Code/project/PiliAurora/build/playback-20261003-reset-smoke/smoke.json`
- `E:/Code/project/PiliAurora/build/playback-20261003-graceful-smoke/smoke.json`

三份样本同为 stress 阶段，记录的媒体区间 43042 → 45042 ms。它们是同一数据窗口的重复烟雾样本，不是三个不同负载的独立基准。[REPORT:44–75；上述 JSON 的 results]

| 字段 | 三份共同结果 |
| --- | ---: |
| accepted | 68 |
| rejected | 243 |
| rejectedByTrack 起值 | 172 |
| rejectedByTrack 终值 | 359 |
| rejectedByTrack 差分 | **187** |
| rejectedByMemoryBudget 差分 | 0 |
| rejectedByActiveItemLimit 差分 | 0 |
| rejectedByRaster 差分 | 0 |
| outerActiveRejections 保存值 | 0 |
| outerSpecialRejections 保存值 | 64 |
| active 起值 / 终值 | 117 / 185 |

**已确认的对账异常：** `187 + 64 = 251`，超过 `rejected = 243`，差 8。若窗口一致，原因计数与外层拒绝不可能通过这个加法解释所有结果。既有报告明确说部分保存值包含 warmup，最终工具已改用窗口差分。[REPORT:75]

**尚未确认：** 具体是哪份生成工具版本、哪项外层字段含 warmup，或是否还有其他快照口径差异。JSON 没有按类型分解轨道拒绝；本次未重新启动播放器。不能把差 8 直接认定为当前 admission 算法缺陷，也不能擅自把 outerSpecial 改写为推算值。

当前工具已经在测量开始、结束分别取统计快照，并对 accepted/rejected、outerActive/outerSpecial 求差；renderer 的 statisticsBefore/statistics 保存的仍是累计快照，需要分析方求差。[B:530–557,582–588,616–617]

当前配置为 `massiveMode: true`，锁定选项默认 `static2Scroll: false`。**代码推论：** 在非零轨道且资源门槛通过的当前配置下，滚动弹幕不会因找不到轨道落入 rejectedByTrack；该路径的轨道拒绝只能来自静态弹幕。**历史样本归因假设：** 若保存样本使用相同选项，则静态容量是 187 的对应来源；因为保存结果缺少完整选项快照和类型计数，这还不是历史运行的直接类型证据。[B:127; UO:64–75; R:259–298]

另读了 `E:/Code/project/PiliAurora/build/playback-20261003-debugger/result.json` 的数值字段：媒体位置 40084 → 40084 ms，accepted/rejected 及四类拒绝差分均为 0。它没有有效的移动输入窗口，不用于算法效率或容量比较。[REPORT:46]

## 5. 滚动追赶判据：为什么拒绝可能是正确结果

令：

- W：视口宽度。
- r：尾项在当前 tick 的右边缘，即 `xAt(tick) + width`。
- vp：尾项左移速度；vn：新项左移速度，均为正值。

新项从 W 开始。当前谓词要求：

```text
r <= W && (vn <= vp || r * vn <= W * vp)
```

第一项禁止在入口处与尾项重叠。新项更快时，尾项右边缘还要 `r / vp` 时间才离开左边界；届时新项左边缘为 `W - vn * r / vp`。要求该值非负，正好得到第二项。因相对运动是线性的，当前无重叠且离开左边界前不追上，构成对该尾项的可见区域安全条件。等号只在左边界相切，不应任意改成严格小于而增加拒绝。[T:22–23,39–49; R:158–185,277–286,563–565]

在变速模式下，`v = (W + width) / durationMs`；长弹幕速度更高，因此即使尾项已经完整入屏，也可能合理拒绝其后的一条长弹幕。固定速度模式下，`v = W / durationMs`，没有这一追赶速度差。[R:158–160]

锁定上游使用的追赶式与上述式在相同 duration、变速模式下等价：

```text
r * (W + nextWidth) <= W * (W + previousWidth)
<=> r * nextWidth <= W * (W - previousX)
```

右侧正是上游检查使用的条件。不能仅因为 Windows 改为基于速度的表达式，就称其比上游更严格。[US:423–439]

### 已执行的数值交叉检查

用 PowerShell 内存表达式核对下列四个边界，无新增脚本文件。此项是数学 oracle，**不是调用 Dart renderer 的运行测试**。

| W | r | vp | vn | 当前谓词 | 尾项出屏时新项左边缘 |
| ---: | ---: | ---: | ---: | --- | ---: |
| 100 | 110 | 0.06 | 0.06 | 拒绝：入口尚未清空 | -10 |
| 100 | 60 | 0.06 | 0.11 | 拒绝：会追上 | -10 |
| 100 | 60 | 0.06 | 0.10 | 接受：左边界相切 | 0 |
| 100 | 100 | 0.06 | 0.06 | 接受：入口相切、等速 | 0 |

现有 TT:31–37 已用实际 Dart 方法验证“尚未相交但未来会追赶”的拒绝。TT:45–71 的 1000 组随机测试验证的是 `overlapsDuring` 的保守合成判断，**不是**轨道分配谓词的完整性质测试。

## 6. 可重复输入、潜在问题与确认级别

### A. 静态池正常满轨拒绝——不是 bug

复用 RT 的一轨条件，设置 `massiveMode: true`、`static2Scroll: false`、staticDuration 1 秒。

1. 同 tick 添加一个短顶部静态项，应接受。
2. 再加顶部或底部静态项，应拒绝，track 计数增 1；海量模式不改变该结果。
3. advance 999 ms 后仍应拒绝；再 advance 1 ms 后槽位释放，添加应接受。

**研究阶段确认级别：** 源码确定；本代理当时未新增该专用测试。主代理后续静态容量及到期边界测试通过，见第 12 节。顶部与底部共池、advance 按静态 endMs 释放的证据是 R:261–270,308–315,372–394。宽度正常、资源预算足够是场景前提，避免把 raster/memory 拒绝混入断言。

### B. 正常滚动突发与长弹幕追赶——合理拒绝

一轨、massiveMode false、selfSend false；短滚动项入场后不 advance，第二项因入口未清空被拒绝。等速场景 advance 至前项右缘 <= W 后可接受；变速长后项还要满足第 5 节的追赶式。不能只以“屏幕左侧有空白”认定轨道可用。[R:277–298; T:39–49]

**研究阶段确认级别：** 实际追赶方法已有测试通过；renderer 的拒绝计数边界当时尚缺专项断言。主代理后续普通滚动突发测试通过，见第 12 节。

### C. 零轨道返回 false，但 track 计数不增——统计语义，不是选轨故障

configure `Size.zero` 后添加普通或高级弹幕会在选轨前返回。现有 RT:251–277 验证普通 add=false、trackCount=0，但没有验证计数。

**确认级别：** 已有运行测试加源码确认。建议以后单列 `unavailable/noTracks`，而不是悄悄改变 rejectedByTrack 的历史含义。[R:202–213]

### D. 静态转滚动绕过 hideScroll——研究阶段发现，后续主代理红绿验证已完成

一轨，static2Scroll true、hideScroll true、hideTop false；填满静态池后再加顶部静态项。前置判断只检查源类型 top，后续把 scrolling 设为 true，却未检查隐藏滚动选项；滚动池空时可被接受。超宽顶部静态项也能触发同一转换。[R:203–205,261–287]

锁定上游在转换前要求 `!_option.hideScroll`。[US:247–254] Windows configure 又会移除 `entry.scrolling && hideScroll` 的活动项，使“configure 不允许、后续 add 又允许”的行为不一致。[R:467–470]

**研究阶段确认级别：** 源码可证明的目标类型检查缺口；本代理当时未执行新的实际 renderer 回归测试，未声称已经修复。以下为当时的下一步建议；主代理后续已得到满轨及超宽场景红灯，并已提供修复后的 green，见第 12–13 节。下一步应先补“满静态池/超宽静态 × hideScroll”的 red-capable 测试。若要求与上游隐藏规则一致，再修转换条件。它会增加部分本应拒绝的计数，不是以降拒绝为目标的优化。

### E. 满轨静态 selfSend 的兜底差异——需要产品策略决定

一轨、static2Scroll false；填满静态槽后再添加 selfSend 顶部/底部项。Windows 不进入滚动分支，因此拒绝并增加 track 计数；上游 `_handleNormalDanmaku` 的 selfSend 兜底不限定 scroll，会放入第 0 滚动轨。[R:261–298; US:220–228]

**确认级别：** 固定源码差异。未确认 Windows 是有意限制静态 selfSend，还是兼容遗漏。不应直接恢复上游行为；先决定自发静态弹幕是否允许改类型叠加、以及 hideScroll 时如何处理。

### F. 仅检查尾项的适用条件——放宽分配前要验证，不是本次高拒绝的已知根因

普通路径只看 insertion-order 的 `lastOrNull`，不是检查该轨全部项。selfSend/massive 的强制插入和 configure 的轨迹变更意味着不能对所有状态默认使用“整条轨道无重叠”的不变量。[R:278–293,463–505]

可构造一个**尚未运行实际 renderer 的几何场景**：W=100、durationMs=2000，同时进入宽 100 的普通项 A 与宽 20 的 selfSend 项 B。500 ms 时 A 右缘 150、B 右缘 90；再来宽 20 的普通项 C，尾项谓词接受，但 C 的入口与 A 相交。真实文本需要用测量宽度构造对应条件，不能假称已经得到这些精确 raster 尺寸。

当前 `_recordOverlap` 会检查所有活动普通项，并使绘制回退到组透明度；它保护合成语义，不会撤销已经接受的项。[R:188–199,308–311,563–584] 是否允许已有强制叠加轨道继续接受普通项，需要产品定义。本例只说明以后更换尾项数据结构、增加拒绝跳过判据或宣称完全防重叠时必须包含此类测试。

## 7. 安全优化方案与风险

### 优先级 1：分类与短测试，不改变入场策略

在后续获准修改时，增加按类型的互斥 add 结果，例如：accepted、staticFull、scrollEntryBlocked、scrollCatchUpBlocked、noTracks、hidden、rasterGuard、memoryBudget、activeLimit、rasterUnavailable、disposed。保留现有字段，增加统计 schema/策略版本，不把旧字段重新定义为总拒绝。[R:101–125,202–300]

为了避免重复扫描，滚动失败的细分原因应在当前选轨循环中汇总：每个轨道可能有不同失败原因；需要声明结果是“全轨入口阻塞”“存在已清入口但追赶失败”还是按优先级聚合，不能把每轨失败次数当作每条弹幕拒绝次数。还需单列强制兜底接受数、静态转滚动数。[R:277–293]

基准同时记录完整 DanmakuOption、逻辑视口、measuredTrackHeight/trackCount、DPR、类型尝试数、同窗口 outer 拒绝及未分类 false。建立：

```text
windowRejected = windowRendererFalse + windowOuterActive + windowOuterSpecial
windowRendererFalse = sum(互斥且完整的 renderer 原因计数)
```

旧四字段不是完整分类，不能要求它们单独满足第二式。快照须在同一个无 await 的区段取值；clear/重建/seek 分段重新建基线，不跨实例求差。[B:530–557]

**风险：** 新统计自身增加热路径开销；不要每次拒绝写日志，也不要记录正文。用整数聚合与现有快照即可。类型计数只表示 renderer 输入，仍不包括生产前置过滤。

### 优先级 2：静态满槽的廉价预判，降低拒绝成本

当普通静态输入、static2Scroll false、静态池已满时，接受结果不需要新文本宽度；目前仍先执行 rasters.get 和活动预算判断，再发现静态池满。[R:250–275; RC:88–132]

可以在获准的实验中研究满槽预判，先用现有槽位扫描，**不急于引入位图、堆或新依赖**。如果后续证明扫描本身有成本，再考虑维护静态空槽计数；需要覆盖 add、advance、configure、clear 和 dispose 的一致性。[R:128–156,372–421,459–506,627–647]

**必须处理的语义风险：** 提前拒绝会把当前 raster/memory 优先归因改成 track，减少 cache layouts/hits，并改变 LRU/paragraph 留存。非法超大静态文本原本计入 raster 拒绝，提前满槽返回后会变成容量拒绝。不能在声称“拒绝统计完全不变”的同时这样重排。选择保持原优先级的受限快速路径，或明确升级统计策略版本并双口径比较。

**待验证的性能假设：** 满槽静态输入使无用 layout、paragraph 留存和 cache 条目压力增加；预判可能降低单次 add 成本。这些是从执行路径得到的假设，没有本次性能 A/B 数值。轨道拒绝在当前路径发生于 rasterize 之前，不能声称优化会为每条拒绝省去一次原本不存在的 add 内栅格化。[R:295–300]

预热路径独立于能否入轨，已会为未来普通项生成图像；因此即使 add 预判生效，也未必消除预热的栅格化和 Cache 压力。[R:322–368; B:399–415]

### 优先级 3：滚动入口预判，只在明确适用时研究

在无强制兜底的普通滚动场景，如果所有候选尾项右缘仍 > W，则无需知道新宽度就知道当前无法安全入场。可研究这一廉价预判，条件是使用与当前谓词相同的 tick、空轨和尾项状态，并处理第 6F 节的特殊轨道状态。[T:45–48; R:277–293]

**风险：** 同样会改变 raster/memory 的失败优先级；两次扫描可能比一次带 layout 缓存命中的扫描更慢。变速模式的追赶可用时间依赖新宽度/速度，不能随意替换为一个与内容无关的“轨道 readyAt”。没有基准支持时保持现有线性扫描。

### 暂不推荐的“优化”

- 提高 active memory 或 Cache：不能修复静态满槽，且会增加账面预算和资源风险。[R:54–64,128–156]
- 降行高、增加 area 或取消 safeArea：改变布局、字幕可读性和重叠风险，不属于无行为变化性能优化。[R:128–146]
- 对静态启用 massive 或默认 static2Scroll：改变显示类型、时长、遮挡和用户预期；转滚动还可能增加组合成、活动图像与重叠压力。[R:158–185,188–199,271–315]
- 删除追赶检查：会接受会追上的弹幕；TT:31–37 已有直接反证。
- 对拒绝项排队重试：改变原始时间戳对应的展示时间，还需设计丢弃期限、上限、seek/clear/隐藏状态处理。[B:423–449; V:128–133]

## 8. 已运行验证及覆盖缺口

在 `E:/Code/project/PiliAurora` 执行：

```powershell
flutter test --no-pub test/pages/danmaku/trajectory_test.dart test/pages/danmaku/windows_renderer_test.dart test/pages/danmaku/windows_experiment_test.dart test/pages/danmaku/render_guard_test.dart --reporter expanded
```

**结果：退出码 0，30 个测试全部通过，末行 `All tests passed!`。** 未运行应用播放器，也未安装/更新依赖。测试框架使用其正常派生构建缓存；没有新增测试源码。

相关已覆盖点：

- 实际追赶方法与 overlap 几何，TT:24–71。
- 一轨海量/selfSend 叠加、600 活动上限，RT:141–157；没有拒绝原因计数的断言。
- 缓存、像素合成、活动寿命、暂停、DPR/配置变更，RT:47–138,160–278,282–343。
- 零轨道 add=false，RT:275–277；没有 track 拒绝统计断言。
- Screen 隐藏/祖先 TickerMode 与预热、每帧无 widget rebuild，ET 中相应测试。

**研究阶段覆盖缺口：** 当时尚无静态满轨分类、top/bottom 共池、static2Scroll 与 hideScroll 组合、静态 selfSend parity、正常滚动满轨计数、clear 累计语义以及“拒绝总数可对账”的专用回归。现有测试通过不代表这些策略已验证正确。

## 9. 可执行下一步与验收条件

本节是后续建议，**本次未获得实现/新增测试文件授权，因此没有执行这些修改**。

### 第一步：在现有 renderer 测试中补短、固定时钟场景

复用 RT:10–22 的辅助方法；统一使用一轨配置：

```dart
final renderer = WindowsDanmakuRenderer<void>(
  option: _option.copyWith(area: 0.3, safeArea: false),
  size: _size,
);
expect(renderer.controller.trackCount, 1);
```

| 用例 | 输入/操作 | 核心验收 |
| --- | --- | --- |
| 静态容量 | massiveMode true；top 填满后加 bottom；advance 到到期前/到期时 | 共池；只在容量失败时 track +1；到期后可接受；这是正常拒绝 |
| 正常滚动入口 | 同 tick 两条短 scroll，massiveMode false | 第二条 false；track +1；rasterizations 不因这次 add 拒绝增加 |
| 追赶边界 | TT 的相对速度组合，另测相切等号 | 捕获未来追赶；相切不过度拒绝；速度/宽度关系按当前公式 |
| 强制滚动兜底 | 同一突发分别 massiveMode true、selfSend true | 允许叠加；不计 track；组透明度回退；资源上限仍有效 |
| 零轨道/隐藏 | Size.zero；hideTop/hideScroll；活动数未满 | false，但当前 track 不增；作为统计契约锁定 |
| 转滚动目标隐藏 | 填满静态池或加入有效超宽 top，static2Scroll true、hideScroll true | 若采用上游隐藏规则，第二次 add 必须 false；预期可捕获现有控制流缺口 |
| selfSend 静态 | 静态满池、static2Scroll false 的 selfSend top/bottom | 先记录当前拒绝，再由产品决定是否要求上游滚动兜底；不要先写死兼容结论 |
| clear/configure | 先制造一次拒绝，然后 clear；另缩轨、调 duration | 累计计数不被 clear 重置；配置丢弃与 add 拒绝分开；无悬空轨道引用 |

样例断言（建议放在一个获准新增的测试内，下面片段本次未执行）：

```dart
renderer.updateOption(renderer.controller.option.copyWith(
  massiveMode: true,
  static2Scroll: false,
));
final before = renderer.rejectedByTrack;
expect(renderer.add(_text('a', type: DanmakuItemType.top)), isTrue);
expect(renderer.add(_text('b', type: DanmakuItemType.bottom)), isFalse);
expect(renderer.rejectedByTrack, before + 1);
renderer.advance(const Duration(milliseconds: 1000));
expect(renderer.add(_text('b', type: DanmakuItemType.bottom)), isTrue);
renderer.dispose();
```

先执行指定单文件，再执行第 8 节四文件命令。任何 hideScroll 语义修复都必须先有能捕获该路径的失败测试，而不只看总体通过数。

### 第二步：短离线 admission 回放与分类对账

使用已有本地弹幕数据，只把元素转成 renderer 输入并用 `advance(Duration)` 推进固定时钟；不需要 mpv、Video 或真实播放器。先复刻 warmup 3 秒 + measurement 2 秒的媒体窗口，再增加一个覆盖 staticDuration 到期边界的短窗口。

- 固定实际逻辑视口、字体、DPR、选项、输入次序；先用 synthetic fixture 保证可重复，再用真实数据验证。
- 同时统计按 type 的尝试/接受/拒绝、各原因的窗口差分、轨道数及每池占用；避免弹幕正文和身份标识输出。
- 明确是否启用预热；入场算法对比先关闭预热，整条优化路径对比另开预热，防止把两者的 rasterizations 混为一项。
- 对账必须严格成立；若仍有未分类 false，报告该字段，不用四原因之和替代总拒绝。
- 当前 fixed massive 配置下若出现 scroll 类型的 track 拒绝，先查配置快照、实例切换和计数实现，而不是直接放宽判据。

**验收：** 同一 fixture 重复三次，逻辑接受序列与原因计数完全一致；包括窗口边界、clear 和配置变化的预期结果。性能时间不要求逐次相同。

### 第三步：只有成本证据存在时实施受限优化

先测分类型 add 成本、layouts/cacheHits/rasterizations、条目/字节淘汰及短帧性能，再单独实现静态满槽预判候选。不要同时改变缓存预算、轨道数量或叠加策略。

**验收：** 所有已定义接受/拒绝策略测试保持通过；预判的统计策略差异可解释且对账成立；完整保留 hideScroll、资源上限和组透明度保护；有效显示序列无意外变化；成本结果在相同输入、预热条件和预算下可复核。无改善则撤销候选，不推进 readyAt/heap 等更复杂结构。

## 10. 剩余限制

- 研究阶段本代理没有新增 red-capable 测试文件，所以 6D/6E 的来源差异当时尚无专用运行证据。主代理后续已为 6D 提供满轨及超宽两个红灯；6E 的策略仍待确认。交叉验证详情见第 12 节。
- 历史 JSON 缺少完整选项与按类型计数，且有 warmup 口径差异，无法直接证明 187 的每条拒绝来源。
- 尚无“降低静态满槽 layout 成本”的性能 A/B；不能宣称已经改善 Windows 播放性能。
- 未要求主代理重复研究本主题；原生退出的复现修复仍属于主代理的独立工作，本报告不对其做结论。

## 11. 主代理请求的进展与最优先测试组

用户补充：主代理已用真实 Flutter 引擎隔离测试确认 runner 生命周期错误，正在修复和验证。此状态来自用户信息，本研究未独立核验 runner，不触碰对应文件。后续不再做在线 API 研究；下述建议仅依赖本仓库及已锁定本地源码。

### 研究阶段进展（后续交叉验证见第 12 节）

- 研究正文、文件/行号证据、拒绝语义、历史样本差分及优化风险已整理完成。
- 四个现有测试文件共 30 个测试通过，未新增或修改测试源码。
- 最高价值的下一组是 **“一轨静态容量 × 静态转滚动 × hideScroll”**，而不是继续提高活动内存或 Cache。
- 这组直接覆盖当前基准的静态容量语义，并提供一个针对隐藏目标类型缺口的 red-capable 用例。它不依赖网络、真实播放器、系统时钟或原生窗口。

### 一组五个确定性测试

| 编号 | 配置/操作 | 预期 | 当前源码预测 |
| --- | --- | --- | --- |
| P1 | 一轨，massive=true，static2Scroll=false；先 top 再 bottom；随后 clear | bottom 容量拒绝，track +1；clear 不清计数；clear 后可重新接受 | 应通过：锁定合理拒绝及计数定义 |
| P2 | 同一配置；top 入场后 advance 999 ms，再 1 ms | 999 ms 槽位仍满；1000 ms 槽位释放 | 应通过：锁定容量恢复的精确边界 |
| P3 | static2Scroll=true，hideScroll=false；top 填满静态池后加 bottom | bottom 转到空滚动池，接受；track 不增 | 应通过：证明同一输入的转换条件 |
| P4 | 与 P3 只差 hideScroll=true | bottom 不得进入隐藏滚动池，add=false | **研究阶段预计失败**：修复前转换遗漏目标类型检查，R:271–287；当时未运行专用测试，后续主代理红灯已确认，见第 12 节 |
| P5 | configure Size.zero，然后 add | false，但当前 track 计数不增 | 应通过：证明 false 不等于 rejectedByTrack |

P4 的目标是上游隐藏规则及本仓库 configure 的一致性：[US:247–254; R:467–470]。它不把普通满轨当作缺陷。目标隐藏时究竟计为 staticFull、hidden 或其他新原因，应由后续分类方案决定；本组不先规定该用例必须增加哪个新计数。

### 可复用片段（建议加入现有 RT 的 main 内）

以下片段复用现有 `_option`、`_size`、`_text` 和 imports；**仅存于本研究文档，未作为 Dart 源码编译或运行，也没有写入测试文件**。每个测试创建独立 renderer，使用 addTearDown 释放资源；短 ASCII 内容规避超宽和单项 raster 保护的干扰。

```dart
group('static track admission semantics', () {
  WindowsDanmakuRenderer<void> oneTrack({
    bool static2Scroll = false,
    bool hideScroll = false,
  }) {
    final renderer = WindowsDanmakuRenderer<void>(
      option: _option.copyWith(
        area: 0.3,
        safeArea: false,
        massiveMode: true,
        static2Scroll: static2Scroll,
        hideScroll: hideScroll,
      ),
      size: _size,
    );
    addTearDown(renderer.dispose);
    expect(renderer.controller.trackCount, 1);
    return renderer;
  }

  test('P1 top and bottom share static capacity even in massive mode', () {
    final renderer = oneTrack();
    expect(renderer.add(_text('a', type: DanmakuItemType.top)), isTrue);
    final rasterizations = renderer.rasters.rasterizations;
    expect(renderer.add(_text('b', type: DanmakuItemType.bottom)), isFalse);
    expect(renderer.rejectedByTrack, 1);
    expect(renderer.rejectedByRaster, 0);
    expect(renderer.rejectedByMemoryBudget, 0);
    expect(renderer.rejectedByActiveItemLimit, 0);
    // 满轨拒绝发生在 add 内栅格化之前。
    expect(renderer.rasters.rasterizations, rasterizations);
    expect(renderer.scrollDanmaku.single, isEmpty);
    renderer.clear();
    expect(renderer.rejectedByTrack, 1);
    expect(renderer.staticDanmaku.single, isNull);
    expect(renderer.add(_text('b', type: DanmakuItemType.bottom)), isTrue);
    expect(renderer.rejectedByTrack, 1);
  });

  test('P2 static capacity recovers exactly at the lifetime boundary', () {
    final renderer = oneTrack();
    expect(renderer.add(_text('a', type: DanmakuItemType.top)), isTrue);
    renderer.advance(const Duration(milliseconds: 999));
    expect(renderer.tick, 999);
    expect(renderer.add(_text('b', type: DanmakuItemType.bottom)), isFalse);
    expect(renderer.rejectedByTrack, 1);
    renderer.advance(const Duration(milliseconds: 1));
    expect(renderer.tick, 1000);
    expect(renderer.staticDanmaku.single, isNull);
    expect(renderer.add(_text('b', type: DanmakuItemType.bottom)), isTrue);
    expect(renderer.rejectedByTrack, 1);
  });

  test('P3 static fallback uses an available visible scroll track', () {
    final renderer = oneTrack(static2Scroll: true);
    expect(renderer.add(_text('a', type: DanmakuItemType.top)), isTrue);
    expect(renderer.add(_text('b', type: DanmakuItemType.bottom)), isTrue);
    expect(renderer.rejectedByTrack, 0);
    expect(renderer.staticDanmaku.single!.content.text, 'a');
    expect(renderer.scrollDanmaku.single, hasLength(1));
    expect(renderer.scrollDanmaku.single.single.content.text, 'b');
  });

  test('P4 static fallback must not enter a hidden scroll track', () {
    final renderer = oneTrack(static2Scroll: true, hideScroll: true);
    expect(renderer.add(_text('a', type: DanmakuItemType.top)), isTrue);
    // 研究阶段预测此断言失败；后续主代理已证实红灯，见第 12 节。
    expect(renderer.add(_text('b', type: DanmakuItemType.bottom)), isFalse);
    expect(renderer.staticDanmaku.single!.content.text, 'a');
    expect(renderer.scrollDanmaku.single, isEmpty);
  });

  test('P5 no tracks is an early false, not a track allocation rejection', () {
    final renderer = oneTrack();
    renderer.configure(size: Size.zero);
    expect(renderer.controller.trackCount, 0);
    expect(renderer.add(_text('a', type: DanmakuItemType.top)), isFalse);
    expect(renderer.rejectedByTrack, 0);
    expect(renderer.rasters.layouts, 0);
  });
});
```

获准添加测试后，在 `E:/Code/project/PiliAurora` 运行：

```powershell
flutter test --no-pub test/pages/danmaku/windows_renderer_test.dart --plain-name 'static track admission semantics' --reporter expanded
```

研究阶段建议的预期流程（当时 green 待提供；主代理现已报告红绿验证完成，见第 12–13 节）：先确认 P1/P2/P3/P5 通过、P4 以隐藏转换错误失败；若真实结果与预测不同，停止按此假设修复并检查实际配置/版本。只在隐藏规则确认后修改对应转换条件，再复跑这组及第 8 节四文件命令。不要把减少 P1 的合理拒绝作为验收目标。

这组暂不包含静态 selfSend 兜底差异，因为那一项需要先决定产品策略，不能把上游 parity 自动当成当前 Windows 的正确性契约。

## 12. 主代理交叉验证补记（2026-10-03）

### 来源、范围与红灯阶段状态（最新 green 见第 13 节）

本节根据主代理经用户提供的交叉验证结果补记。本代理未代跑测试，未修改实现或测试文件，也未独立核验拟修复是否已落盘。第 1–11 节中的“未复现／待补／预计失败”和 30 个既有测试通过均为本代理研究阶段记录。

- 主代理已在 `E:/Code/project/PiliAurora/test/pages/danmaku/windows_renderer_test.dart` 末尾追加 **6 项测试**；原有测试和实现证据行号未因追加测试而改变。
- 主代理报告的红灯日志：`E:/Code/project/PiliAurora/build/track-rejection-red-20261003.log`。
- 红灯阶段主代理拟修复 R:273 附近的静态转滚动条件，并保持源码行数；后续已报告修复后 green，见第 13 节。
- **红灯阶段记录：当时红灯复现已由主代理确认，green 尚待提供，因此当时不宣称修复验证完成。最新状态：主代理已提供 green，见第 13 节。**

### 主代理已报告的结果

以下列的是测试场景与参数组合，不把每个参数组合另算成一项新增测试。

| 场景 | 主代理交叉验证结果 | 对研究结论的影响 |
| --- | --- | --- |
| 静态池满轨 | 通过 | 支持正常静态饱和拒绝，不是把容量拒绝当作 bug |
| 静态寿命 999 → 1000 ms 的槽位释放 | 通过 | 支持精确到期边界和容量恢复逻辑 |
| clear 后累计拒绝计数保留 | 通过 | 支持 rejectedByTrack 的实例累计语义 |
| 普通滚动突发 | 通过 | 支持入口未清空时的合理拒绝；不证明所有宽度组合均已覆盖 |
| static fallback、hideScroll=true、静态满轨 | **红灯：Expected false，Actual true** | 研究阶段的隐藏目标检查缺口获得实际运行证据 |
| static fallback、hideScroll=true、静态超宽 | **红灯：Expected false，Actual true** | 同一缺口还覆盖超宽转换，不只是静态槽位不足 |
| hideScroll=false 的满轨及超宽转换 | 两个场景均通过 | 允许可见滚动转换的正向路径已有交叉验证；修复不得误伤 |

**更新后的判断：** 本次明确复现的是“向隐藏滚动池转换时漏拒绝”，不是“正常轨道饱和导致误拒绝”。已有容量拒绝测试通过，不支持通过扩大轨道、默认强制叠加或删除追赶判据来处理这个缺口。静态 selfSend 的上游差异、历史 JSON 对账和更完整性质测试仍没有因本次红灯验证而自动解决。

### 主代理在红灯阶段提供的拟修复方案（后续 green 见第 13 节）

在 R:271–274 的转换分支中，仍保留 `track = -1`，只将：

```dart
scrolling = true;
```

改为：

```dart
scrolling = !_option.hideScroll;
```

保持行数，原证据行号继续可用于定位。

**红灯阶段代码推论，当时 green 待验证；后续主代理报告的验证结果见第 13 节：** hideScroll=true 时不进入滚动分配，且 track 仍为 -1，随后由既有未选到轨道分支返回 false 并增加 rejectedByTrack。hideScroll=false 时保持原滚动转换行为。[R:271–298]

对于“静态槽位可用，但文本超宽且 static2Scroll=true、hideScroll=true”的组合，也不直接保留为静态项：转换分支先撤销候选 track，再拒绝隐藏目标，以保持锁定上游“超宽静态要求转换，但隐藏滚动时不转换”的语义。[US:178–182,247–254]

该修复意图是补足必要拒绝；部分 track 拒绝可能因此增加，不能用“拒绝总数下降”作为验收条件。它不是扩大静态容量或改变海量模式的优化。

### 红灯阶段的 green 验收要求（主代理现已提供结果）

红灯阶段本代理不代跑测试，原计划待主代理提供 green 后补记命令、数量、日志与范围，当时保留“红灯已确认、拟修复、green 待验证”的状态。该等待现已结束；最新结果记录于第 13 节，本代理仍未代跑验证。

green 至少应证明：满轨/超宽的 hideScroll=true 两个红灯转绿；hideScroll=false 两个正向场景仍通过；静态容量、999→1000 ms、clear 累计计数及普通滚动突发行为保持通过。整组通过不自动等于历史 JSON 对账完成，也不等于所有 renderer 性质和播放性能均已验证。

## 13. 主代理 green 与静态检查补记（2026-10-03）

### 结果来源与最新状态

本节仅根据用户提供的主代理最终结果补记。未增加研究范围；本代理未代跑测试或 analyze，未修改实现或测试文件，也未独立读取和复核完整日志。

**最新状态：主代理已确认修复后的相关回归测试 green，57 项全部通过；相关 6 个目录/文件的 analyze 为 `No issues found`。隐藏目标转换缺口已完成主代理报告的 red → 修复 → green 验证。** 第 12 节的“拟修复／green 待验证”保留为红灯阶段历史记录，不是当前状态。

### 主代理最终测试结果

主代理在 `E:/Code/project/PiliAurora` 执行的命令：

```powershell
flutter test --no-pub test/pages/danmaku test/services/diagnostics_test.dart test/plugin/pl_player/video_output_size_test.dart --reporter expanded
```

- 主代理报告结果：**57 项测试全部通过**。
- 日志：`E:/Code/project/PiliAurora/build/takeover-tests-final-20261003.log`。
- 测试范围：弹幕测试目录、diagnostics 测试和 video_output_size 测试。命令包含追加在 Windows renderer 测试末尾的轨道验证场景。
- 根据该整组 green，前述 hideScroll=true 的满轨、超宽两项红灯已转绿；hideScroll=false 两个正向转换场景及静态容量、到期释放、clear 累计计数、普通滚动突发回归保持通过。
- 本次 57 项是主代理最终命令的通过数量，不与本代理研究阶段的 30 项相加；两次命令范围及源码阶段不同。

### 主代理静态检查结果

- 主代理报告：相关 **6 个目录/文件** analyze，结果 **`No issues found`**。
- 日志：`E:/Code/project/PiliAurora/build/takeover-analysis-final-20261003.log`。
- 主代理核实的完整命令如下；不是全仓库 analyze：

```powershell
flutter analyze --no-pub lib/pages/danmaku lib/services/diagnostics test/pages/danmaku test/services/diagnostics_test.dart tool/danmaku_playback_benchmark.dart tool/windows_runner_lifecycle_fixture.dart
```

### 最终结论及保留边界

1. 正常静态饱和、普通滚动入口阻塞仍属于合理拒绝；本次没有发现或修复这两类拒绝的误拒绝问题。
2. 已修复并由主代理报告 green 的问题是静态转滚动时进入隐藏目标的**漏拒绝**。`scrolling = !_option.hideScroll` 配合保留 `track = -1`，使满轨与超宽隐藏转换均被拒绝，可见滚动转换继续允许。
3. `massiveMode` 不改变静态池正常容量，也不应绕过 hideScroll；修复增加必要拒绝不属于性能退步或容量算法缺陷。
4. 本次 green 不自动解决静态 selfSend 的策略差异、历史 JSON 的拒绝口径对账，也不证明完整几何性质或播放性能改善。这些限制沿用原报告，不增加后续研究任务。

**本代理仅完成研究文档与交叉验证结果补记；实现修复、测试执行和静态检查归属于主代理。**

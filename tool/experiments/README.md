# 按需实验

在仓库根目录通过 FVM 运行，使用与正式测试相同的项目依赖：

```powershell
fvm flutter test tool/experiments/
```

此目录不进入默认 `fvm flutter test` 的 `test/` 扫描。可将单个文件路径传给命令，独立运行对应实验。

| 文件 | 内容 |
| --- | --- |
| `danmaku/raster_cache_capacity_test.dart` | 对照 16/24/32 MiB 缓存容量在唯一内容、重复内容和预热扫描中的命中、光栅化与淘汰；检查预算和预期命中关系。 |
| `danmaku/file_order_reuse_test.dart` | 用真实 protobuf 临时文件对照每次范围重建外部排序、来源排序产物冷构建和复用读取；核对相同范围内容、稳定次序、解码扫描量、产物复用及清理，输出宿主 CPU/磁盘耗时。 |
| `danmaku/density_metrics.dart`、`density_metrics_test.dart` | 共享视口裁剪、逐权重显示及拥挤统计，验证不可见项、曝光积分、相对Top-N对照。 |
| `danmaku/retention_budget_test.dart` | 完整真实分段及六分钟合成流，对照16/20/24MiB、30000/36000/42000条来源额度。 |
| `danmaku/relative_density_analysis.py` | 将多组聚合报告汇总为逐权重CSV、JSON及Markdown，保留各配置实际覆盖的范围数。 |
| `danmaku/priority_density_test.dart` | 使用可选真实弹幕和密集合成素材，统计权重、密度、轨道准入和高权重保留；测量布局耗时，字宽为估算值。 |
| `danmaku/render_density_test.dart` | 使用生产协调器、真实字体和渲染器，对照每桶4/8/12/16/24/32/120条、逐帧4/8条；30秒输入及8秒尾部，记录各权重可见率、面积时长、拥挤近似量、前沿积压和宿主开销。 |
| `danmaku/legacy_danmaku_rebuild_test.dart` | 测量旧弹幕渲染器在 120 个动画帧中的 widget 重建数和 pump 时间；重建数作为测量结果输出。 |
| `danmaku/baseline/` | 迁移前 Windows renderer/screen 及其专属回归；供像素、排轨、资源和预热对照，生产源码已统一使用窗口内核。 |
| `danmaku/frame_rate_matrix_test.dart` | 遍历屏幕刷新率、视频帧率和弹幕档位，输出合帧与更新统计；适合按需扩大时序诊断范围。 |
| `danmaku/frame_cadence_device_matrix_test.dart` | 将实测120Hz时序中的槽位抖动与回调迟到纳入Android模型，覆盖三种刷新率读数、五个弹幕档位、两种小数视频帧率及250ms/1秒批次，共60种组合；1秒批次和偶发5.7ms迟到为积压压力场景，20–31ms迟到由独立回归覆盖。 |
| `danmaku/frame_wake_lead_test.dart` | 在120Hz/60FPS下对比半屏到1.5屏的唤醒提前量与5/10/20/31.6ms迟到组合，输出最大间隔、长间隔和帧请求数；默认策略仍为半屏。 |
| `danmaku/frame_cadence_analysis.py` | 用 Python 标准库批量比较两份 `cadence.jsonl`，按连续播放段统计更新间隔、skip 截止推进、Timer 迟到和 FrameTiming；默认输出到 `build/frame-cadence-analysis/`。 |
| `danmaku/presentation_continuity_analysis.py` | 用 Python 标准库读取同帧对应的媒体位置和实际呈现时间，保留逐帧数值，汇总跨 1/2/3 帧的差分与 ±1/±2/±3（3/5/7 帧）局部波动，输出 JSON/CSV。 |
| [`android/`](android/README.md) | 隔离诊断包的 EGL 呈现时间与 FrameTimeline 对照，按 EGL 帧 ID 获取实际呈现并关联 Perfetto swap，核对连续性和按需输出成本。 |
| `danmaku/frame_rate_workload_test.dart` | 模拟同步更新耗时和额外 UI 帧，检查更新间隔及停止后的调度释放。 |
| `danmaku/native_video_frame_phase_test.dart` | 对照 Android 与隔离时序模型、mpv 同步和纹理相位，输出锁定状态检查。 |
| `windows/process_metrics_test.dart` | 在 Windows 上检查进程内存与 CPU 采样；其他平台会明确标记跳过。 |

测量使用 Flutter 测试宿主，pump 时间反映本机 CPU 侧重建和缓存状态；GPU 帧耗时在目标设备测量。主测试集保留 `test/pages/danmaku/frame_rate_ticker_test.dart` 和 `native_video_frame_sync_test.dart` 的核心调度与相位回归，扩大矩阵只在实验目录按需运行。

实际呈现分析的输入为已分段的 `presentation-stage-*.json`，包含 `summary`（`run/stage/target`）与 `matched` 数组；每帧字段为 `index/targetUs/positionUs/presentNs`，其中 `presentNs` 必须来自该弹幕更新帧的实际屏幕呈现。暂停、切档和媒体代次分别输入；缺帧、时间倒退和位置回退会中断窗口，首尾采用完整窗口，不补点。一般场景使用滚动＋顶部固定＋底部固定，覆盖固定弹幕进入、驻留和到期。

```powershell
python tool/experiments/danmaku/presentation_continuity_analysis.py <阶段1.json> <阶段2.json> --output build/presentation-continuity
python -m unittest discover -s tool/experiments/danmaku -p presentation_continuity_analysis_test.py
```

`--rate` 指定该测量段的媒体倍速，默认 1。省略 `--output` 时输出每阶段一行完整 JSON，可通过 PowerShell 管道保存。每个阶段独立保留逐帧值、跨 1/2/3 帧的跨度，以及间隔序列滞后 1/2/3 项的差分；±r 窗口包含 `2r+1` 帧和 `2r` 个间隔。窗口记录相对目标间隔误差、相对媒体速率误差的 RMS、呈现延迟极差及总位移速度，汇总数量、均值、分位数、峰值和速度偏差超过 10% 的诊断分桶。长短帧可能抵消窗口总误差，需结合窗口内 RMS 判断；重叠窗口的计数表示覆盖范围。`summary.json/summary.csv` 提供汇总，各阶段 JSON 保留明细。

文件排序复用实验默认生成 9000 条弹幕，对照三个固定 20 秒范围。可单独运行，并通过 `DANMAKU_FILE_ORDER_ELEMENTS` 扩大输入条数（至少 1500）：

```powershell
fvm flutter test --no-pub tool/experiments/danmaku/file_order_reuse_test.dart --reporter expanded
fvm flutter test --no-pub tool/experiments/danmaku/file_order_reuse_test.dart --reporter expanded --dart-define=DANMAKU_FILE_ORDER_ELEMENTS=12000
```

输出的 `DANMAKU_FILE_ORDER` JSON 行包含输入字节/条数、返回范围数量、解码扫描条数/批次数、耗时和排序产物复用/清理结果。计时包含排序构建或复用后的范围扫描及该次流读取退出，来源 store 最终 dispose 清理另行断言，排除测试文件生成和预期结果计算；耗时不作为测试阈值。这是 Flutter 测试宿主上的 CPU/磁盘成本对照，设备 RSS、GPU 和实际播放表现需要目标设备测量。

## 弹幕优先级与密度实验

在候选均可排入的条件下，显示名额按相对权重从高到低分配。例如12个名额面对权重0/3/5/7/10分别10/12/7/2/2条时，应显示权重10的2条、7的2条、5的7条、3的1条。同权重沿用来源次序，自己发送的弹幕优先于服务端权重。实验记录各权重的准入与显示分布；旧字段 `highAccepted/highDisplayed` 的≥8仅用于历史诊断，不能单独用来评判相对优先级。已建立的轨迹保持稳定，因此持续流还需比较跨桶的实际显示分布。

真实下载文件通过进程环境变量传入，原文件只读。报告只保存聚合数据；PNG含本地弹幕正文与视频画面，应保留在忽略的本地目录。

```powershell
$env:DANMAKU_REAL_FILES='<文件一>/danmaku.pb|<文件二>/danmaku.pb'
$env:DANMAKU_DENSITY_REPORT='build/danmaku-density/planner.json'
fvm flutter test --no-pub tool/experiments/danmaku/priority_density_test.dart
$env:DANMAKU_TEST_FONT='C:/Windows/Fonts/msyh.ttc'
$env:DANMAKU_RENDER_REPORT='build/danmaku-density/render'
fvm flutter test --no-pub tool/experiments/danmaku/render_density_test.dart
```

可设置 `DANMAKU_TEST_MERGE=1` 对照后台合并，`DANMAKU_TEST_FPS=30` 检查较低更新频率，`DANMAKU_TEST_CAPS=8,12,16`、`DANMAKU_TEST_PREPARE=8` 缩小配置矩阵，`DANMAKU_TEST_INPUTS=real1,real2` 选择输入。`DANMAKU_TEST_WINDOW=0/1/2` 选择按密度排序且互不重叠的前三个30秒真实范围。默认追加8秒空白尾部，避免范围末尾弹幕还未入画就停止统计；可用 `DANMAKU_TEST_TAIL_SECONDS` 调整。默认覆盖两份可选真实输入和四类合成素材：混合模式密集流、用户示例的持续流、全部权重较低的同分布流、固定12轨道的间隔脉冲。高级弹幕和用户屏蔽规则由正式回归覆盖。可在输出目录放置 `real1-background.png`、`real2-background.png` 作为本地视频背景。

耗时包括协调、测量、轨道布局和图片激活，不含视频解码、真实帧等待和离线拥挤计算。各权重记录原始条数、候选保留数、真正与视口相交的去重显示数、显示率、至少一半面积入画的条数、可见面积时长及入场延迟。包围盒拥挤率是几何近似，不代表文字像素遮挡率。桶内理想Top-N缺项以同桶实际显示数作参照；不同模式、字宽及已建立轨迹会使理想上界无法达到，不能将它当作排序错误率。性能比较应单独运行、重复观察，不设机器相关通过阈值。

默认采用每桶12条、逐帧8条。选择依据和测量边界见下节。

```powershell
fvm flutter test --no-pub tool/experiments/danmaku/density_metrics_test.dart tool/experiments/danmaku/retention_budget_test.dart
python tool/experiments/danmaku/relative_density_analysis.py build/danmaku-relative-20261107
```

### 2026-11-07 配置选择

本轮运行200组显示回放、84组完整来源预算对照和6组Windows Profile实播。真实素材分别含17,499和87,860条弹幕，各取三个互不重叠的高密度30秒范围：素材一33至63、294至324、236至266秒；素材二974至1004、1731至1761、1576至1606秒。范围按弹幕时间选取，末尾可能略超视频结尾；实播仅使用各素材的首个范围。

宿主回放使用微软雅黑、1280×720、25号字，滚动8秒、静态5秒，输入结束后再统计8秒；固定12轨道脉冲使用静态8秒。对照覆盖每桶4/8/12/16/24/32/120条、每帧4/8条、30/60FPS和合并开关。合并以各范围冷启动，未预读前20秒历史，也未按合并条数放大字体。以下8/12/16条结果覆盖相同输入；其他桶上限只测首个范围，不能直接比较累计总量。

未合并的三个真实范围累计如下。各单元格为该权重的“实际可见数／输入数”，可见数按身份去重。

| 素材 | 桶上限 | 总可见 | 权重11 | 权重10 | 权重9 | 权重3 | 权重2 | 权重1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 一 | 12 | 969 | 2/10 | 83/1060 | 218/712 | 608/3243 | 52/336 | 6/44 |
| 一 | 16 | 972 | 2/10 | 81/1060 | 216/712 | 611/3243 | 55/336 | 7/44 |
| 二 | 12 | 2665 | 12/18 | 42/65 | 92/241 | 2286/3822 | 232/491 | 1/8 |
| 二 | 16 | 2666 | 12/18 | 42/65 | 92/241 | 2286/3822 | 233/491 | 1/8 |

12条相较16条在素材一多显示2条权重10和2条权重9，总量少3条；素材二较高权重数量相同，仅权重2少1条。合并后素材一的各权重结果完全相同；素材二仍仅权重2少1条。8条未合并时总可见956和2639条，但素材二的权重11与9分别比12条多1条和3条。较少的最高权重样本不足以推断普遍收益。

持续相对权重合成流的实际可见数为：

| 桶上限 | 权重10 | 权重7 | 权重5 | 权重3 | 权重0 | 总可见 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 8 | 170 | 114 | 228 | 0 | 0 | 512 |
| 12 | 114 | 114 | 259 | 29 | 0 | 516 |
| 16 | 114 | 58 | 203 | 145 | 0 | 520 |

12条相较16条减少了权重3占位，增加权重7与5的显示。将权重改为0/1/2/3/4后，结果按相对次序一一对应。固定12轨道的四次脉冲中，12和16条都按每次2/2/7/1显示，8条每次空出4轨。另一组混合模式合成流中，16条的最高权重10可见237条，12条为227条。因此选择12条是在相对优先、轨道利用率和成本之间取舍，部分输入仍会显示更少的最高权重弹幕。

30FPS下，12条配每帧4或8条均无准备前沿积压；16条配每帧4条在两种持续压力输入中出现798和801个积压帧。默认每帧8条保留了准备余量，本轮未扩大验证高倍速的设备表现。

最后两轮隔离回放中，12条的更新P95在真实素材一为1.298/1.271ms，素材二为1.867/1.889ms；16条分别为1.125/1.157ms、1.743/1.672ms。持续相对权重合成流中，12条为1.920/1.936ms，16条为2.074/2.095ms。12条在真实输入上并非更快；合成持续流的窗口占用从1984项降至1548项。

来源预算采用20MiB／36000条。每桶保留120条时，真实完整普通弹幕分段约16.26至18.12MiB，16MiB会截断，20MiB可完整保留，24MiB无新增收益。六分钟144000条合成流在16/20/24MiB、每桶12条下分别保留27190/34180/41148条，其中最高权重10均为14400条，增加预算主要补充较低权重。显示窗口采用3072项／5MiB，默认实例工作集117MiB；活动栅格96MiB、栅格缓存16MiB、活动数量600和高级活动数量32保持原值。

Windows实播使用原始m4s、D3D11VA和可见窗口，分别对照8/12/16条。实际视口约1265.3×682.7，与宿主回放不同。12条在素材一可见290条，16条292条；素材二均742条。六组均无准备积压，Raster P95约1.6至2.9ms。探针时钟以播放时刻锚定单调时间，未覆盖完整业务播放器时钟，也未采集PresentMon最终呈现。截图中视频纹理底边仍有局部绿色色带，需单独排查。Android、长期功耗和最终GPU呈现未验证。

采用配置后的相关回归与统计器共304项通过，`lib/plugin/pl_player lib/pages/danmaku test tool` 静态分析无问题，普通Windows Profile入口构建成功。原始实验与设备日志保存在忽略的本地目录；仓库仅保留聚合结论和可复用工具。

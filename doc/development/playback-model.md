# 播放器状态模型与反例检查

本模型用于检查播放器周边的业务归属、异步命令、输出和时间线。对应实现是
`PlaybackSession`、`NativePlaybackRuntime`、播放器门面及输出协调器；模型覆盖业务状态与交接协议，原生解码、GPU 呈现和设备行为通过设备探针验证。

## 状态空间

把系统写为带时间的转换系统 `M = (S, E, δ)`：`E` 是用户命令、查询回执、原生事件、
超时及资源释放，`δ(S, e)` 产生新状态。每个 `await` 都是允许其他事件插入的调度点。

```text
S = (phase, stage, owner, g, request, load, runtime, output,
     plan, intent, inhibitors, desired, applied, revisions, pending,
     activeOperation, pendingOperations, writer, anchor, failure, action,
     owners, keepalive, released)
```

| 符号 | 源码含义 |
| --- | --- |
| `owner, g` | 当前页面所有者及其失效代次 |
| `request, load` | 来源查询代次、实际原生加载代次；配置重载可保留 request，但必须改变 load |
| `runtime, output` | 原生运行时身份与输出代次 outputEpoch |
| `desired, applied` | 已接受的目标配置、已获得成功回执的配置 |
| `revisions[k], pending` | 每个配置键的修订号、尚未结算或等待加载的键 |
| `intent, inhibitors` | 用户播放意图，以及页面和会话分别持有的抑制令牌 |
| `activeOperation` | 调度器正在排空的操作；调用方终结后，原生操作仍可能在执行 |
| `writer` | 单独串行协调播放/暂停意图的写入器；最终原生互斥由运行时保证 |
| `anchor` | 媒体位置与单调时间的只读锚点 |
| `released` | Player 实际释放屏障，不能用 shutdown 的调用方超时代替 |

## 不变量与活性条件

### I1：归属与代次

操作的提交条件为：

```text
valid(op, S) = ¬closing ∧ ¬disposed ∧ op.owner = owner ∧ ¬owner.closed
              ∧ op.request = request ∧ op.load = load
              ∧ op.g = owner.g（使用页面 guard 的异步结果）
```

普通控制命令还要求 `phase = ready ∧ ¬owner.requiresLoad`。查询和加载使用各自的
接受请求对象及 deadline。实际原生操作已经开始时可以排空，但返回后的规范状态写入
必须再次检查有效性。页面切换前的媒体结束事件不能变成新页面的完成动作。

原生文件事件还必须经过 playlistEntryId 与文件 binding 核对；输出事件须匹配
`(runtimeId, loadId, outputEpoch)`。不同层的身份不能相互替代。

### I2：意图和事实分离

```text
effectivePlaying = mediaReady ∧ ownerLoaded ∧ intent.playing
                   ∧ sessionInhibitors = ∅ ∧ ownerInhibitors = ∅
```

加载阶段仅在当前加载进入意图协调时允许 `mediaReady` 成立。原生 play/pause 成功只
确认命令写入，`actual.playing` 仍由观测事件更新。令牌释放只能移除持有者的抑制，
不能将用户暂停改为播放。旧 writer 的成功或失败都不能结算新修订的调用方。

独立音频 Player 通过 `AudioSessionHandler` 的租约栈接管声音。当前租约持有视频会话
抑制，等待视频或前一音频的暂停回执后才播放；系统焦点变更串行执行并重新检查归属。
音频页关闭等待创建、open 和 Player 销毁，销毁失败继续持有抑制。系统中断只影响有效
播放，拔耳机更新暂停意图；duck 结束只恢复尚未被用户修改的音量。

独立音频创建抛出 `NativePlayerCreationFailure` 时，仍须等待其 `released` 回执确认
已分配句柄释放。清理未确认时，本页拒绝再次创建，关闭继续持有租约；后续页面先等待
租约交接，再分配 Player，避免旧原生资源尚未释放就创建新的播放器。

### I3：配置收敛与真实结算

对配置键 `k`：

```text
commit(k, r) ⇒ r = revisions[k] ∧ commandCurrent ∧ native.applied
terminal(k, r) ∧ r = revisions[k] ⇒ k ∉ pending
```

第二式适用于已经提交的控制命令；加载期间接受的配置仍可等待完整计划落实。
旧修订的失败不能清除新修订的 pending。相同目标值只有已确认应用时才能直接返回
`applied`；前次失败后必须允许重试，已有请求未完成时不能提前宣告成功。

同内容切源继承最新用户配置后，Session 通过同步的 `configurationForPlan` 核对来源约束；
排队结束、候选轮换和加载期间的配置合并也执行该核对。播放器门面在已知源尺寸超过
屏幕物理尺寸时清除计划中的超分 shader，避免先用旧超分渲染新源首帧、再重载关闭。
尺寸允许的切源保留当前超分档位，其他配置仍按修订合并。

### I4：互斥、时限与释放

```text
|运行时执行中的原生操作| ≤ 1
|某操作槽的排队请求| ≤ 1
deadline = acceptedAt + budget
调用方取消/超时 ⇏ 原生操作已结束 ⇏ 原生资源已释放
createNextPlayer ⇒ previousPlayer.released 已成功完成
```

解析、排队、初始化、打开、输出确认和意图协调共享接受时的总预算；新阶段不能
重新获得整份预算。取消和异常不能毒化串行链。关闭先拒绝新操作，运行时排空、卸载、
释放输出并销毁 Player；只有真实释放回执才能归还资源槽。

Windows 降分辨率、转为纯音频或加载尺寸未知的新源时，旧媒体卸载后再回收渲染器中的
中间资源。同尺寸切源及尺寸未知的同源恢复复用渲染器；降画质与超分变更重合时只重建
一次，重建失败不打开新文件。尚无源几何时使用 1×1 占位输出，原生几何确认后设置
最终限幅尺寸，并等待该尺寸的首帧回执才进入 ready，避免首次高分辨率输出先扩容再缩小。
输出尺寸、原生资源释放计数和进程内存须分别验证。

Windows 每次加载交接在旧文件卸载屏障后，通过跳过绘制的 render 消费 mpv 延迟
reconfig/reset，避免旧帧引用跨到下一次解码器分配。新 load 首个有效共享纹理复制须
确认 GPU 完成，才发布帧及当前 token 的消费身份；等待最多 100ms，失败保留未消费状态。
普通帧沿用异步复制，不能用逐帧等待换取较低峰值。暂停、取消、失败恢复、EOF 和
不同 GPU 的实际画面仍须使用设备探针检查。

活性检查有明确前提：底层操作最终返回时，最新且未超时的请求应可继续执行。
若底层永不返回，调用方仍须在 deadline 终结，但不能为追求继续播放而提前释放资源。

### I5：终态一致性

```text
phase = failed ⇒ failure ≠ null
LoadResult.failed(f) ⇒ 当前失败快照含有同一原因 f
action.completed.owner = 已加载媒体的业务所有者
```

第二式仅在该请求仍是当前请求时适用。被新请求取代的结果不能改写新状态。
结束、失败和关闭均停止媒体时间外推。

### I6：媒体时间与输出交接

对锚点 `A = (p₀, t₀, rate, advancing, ready, continuity, ttl)`：

```text
p(t) = null                                      if ¬ready
p(t) = p₀                                        if ¬advancing
p(t) = p₀ + round(rate × clamp(t − t₀, 0, ttl))  otherwise
```

`rate` 必须有限且大于零。暂停、缓冲、seek 或终态先冻结/失效锚点；恢复后等待新采样。
同一连续域内的旧采样不能覆盖新采样；seekSequence、load 与 owner 改变时隔离旧锚点。

输出尺寸有独立的目标值与已确认值；一次通道调用返回不代表 Flutter 已消费新帧。
保护截图先进入呈现场景，再修改原生几何，消费确认后才撤图；失败且无法确认恢复时
继续保留保护图。源代次失效后旧回执不得更新新源尺寸。

### I7：全屏目标与已确认状态

全屏包含 `target`、`confirmed` 和 `transition` 三种状态。Windows 可以在窗口放大前
预先提交全屏布局；该布局是待确认状态，不能将其等同于原生窗口已经切换成功。

```text
transition 成功 ⇒ confirmed := target
transition 失败 ⇒ UI 回到先前 confirmed
转换期间收到新目标 ⇒ 排空当前转换后落实最新目标
```

进入失败后仍须允许重新进入，退出失败后仍须允许重新退出。页面内全屏不要求原生
窗口放大，但仍需要正确处理进出、失败和并发目标。

### I8：自动续播位置属于媒体的有效区间

来源查询、首次加载、页面恢复和自动重载中的续播位置应满足：

```text
live ⇒ startPosition = reloadPosition = null
非直播 ∧ 已知有效 duration ⇒ 0 ≤ resumePosition < duration
resumePosition < 0 或 resumePosition ≥ duration ⇒ 从 0 重新播放
```

未知或非正时长不能用作上界。原生观测到的有效时长按内容身份保存，不能借用上一视频的
时长裁剪新视频。初次加载才确认提示时长偏长时，纠正后的重新加载仍属于原请求，沿用
同一个 deadline；从 0 仍失败时正常终结，不得循环重开。显式 seek 到片尾的结束语义
与自动续播分开处理。
展示层在新 load 就绪时，应按会话最终接受的起点重新对齐进度投影；否则旧的越界
展示起点会把归零后的真实进度持续当作卸载零值过滤掉。

## 检查方法

1. 沿源码调用关系为每个事件列出提交条件、状态写入和异步边界。
2. 选取会打破不变量的最短事件序列，例如“失败 → 相同配置重试”、
   “旧媒体加载 → 新页面接管 → 旧媒体 EOF”、“旧意图写入 → 新意图 → 旧写入抛错”。
3. 在实际会话/运行时接口注入可控回执，先运行失败用例，再修改实现。
4. Terra（xhigh）执行修复，主代理重新沿模型检查；新反例进入下一轮。
5. 最后一轮没有新的可确认反例，且相关回归与静态检查通过，才结束本轮审查。

## 2026-11-09 检查记录

每轮先在实际代码路径运行失败回归，再由同一 Terra（xhigh）代理修复，并由主代理复审。

| 轮次 | 违反约束的反例 | 修复后的协议 |
| --- | --- | --- |
| 1 | 查询返回空计划，结果失败但快照没有原因；配置失败或不支持后 pending 不清，同值重试却返回成功 | 快照与结果共享失败原因；终态按修订结算；未应用的同值可重试，在途同值返回 accepted |
| 2 | 新 owner 接管后收到旧媒体 EOF；新查询被旧媒体失败污染；旧 writer 抛错结算最新意图 | 结束与失败按媒体归属过滤；writer 异常绑定发起时修订，继续协调最新意图 |
| 3 | 原生全屏失败仍更新 UI；全屏切换期间丢弃反向目标；Timer 未交付时将超过 deadline 的操作判为成功 | 全屏失败恢复已确认状态并落实最新目标；操作返回及抛错时重查绝对时限 |
| 复审 | 方向/系统栏失败后缓存阻止同值重试；失败回滚还可能覆盖更新的同值写入 | 失败恢复缓存，并按写入修订隔离迟到失败 |

回归入口：

```powershell
fvm flutter test --no-pub test/plugin/pl_player/playback/playback_session_test.dart test/plugin/pl_player/playback/playback_model_test.dart test/plugin/pl_player/playback/playback_operation_scheduler_test.dart
fvm flutter test --no-pub test/plugin/pl_player/fullscreen_model_test.dart test/plugin/pl_player/fullscreen_transition_test.dart
fvm flutter test --no-pub test/plugin/pl_player/fullscreen_system_ui_test.dart
```

全屏用例需要 Windows 主机。新增模型回归已进入 `tool/run-ci-tests.ps1` 的对应主机范围。

最终在 Windows 主机合并运行 `test/plugin/pl_player/`、`test/pages/danmaku/`、
视频播放生命周期与来源、直播控制器、音频会话与服务生命周期，以及网格与瀑布流回归，
715 项全部通过。`fvm flutter analyze --no-pub lib/plugin/pl_player lib/pages/danmaku test tool`
无问题；CI 脚本语法及 92 个测试路径有效。末轮对照上述不变量复查，没有新的可确认反例。

## 验证边界

主机测试覆盖已构造的事件排序、状态归属、时限、配置和释放场景。
Android Surface/MediaCodec、Windows 纹理/GPU 的真实呈现、音频焦点和系统全屏效果
通过目标设备验证，并记录设备、输入和结果。

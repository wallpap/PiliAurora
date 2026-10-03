# Windows 播放遥测语义校验

- 校验日期：2026-10-03（Asia/Shanghai）。
- 仓库：`E:\Code\project\PiliAurora`；分支：`codex/windows-playback-experiments-20261003`。
- 范围：静态源码、属性契约、取样边界。未启动播放器，未运行构建、基准或真实弹幕实验。
- 本报告的“建议”是实验控制建议，不是已测得的性能结论。

## 1. 证据与版本边界

| 对象 | 已确认内容 | 边界与来源 |
| --- | --- | --- |
| 本地 media_kit | package_config 指向 Pub Git 缓存；lock 固定 fork 提交 `73771ec38176be2d984a3049c28177bce23b54a0`。media_kit 标称 1.1.11，media_kit_video 标称 1.2.5。 | 本地提交时间为 2026-09-06 20:01:07 +0800。缓存工作树无改动；native player 文件与该提交远程正文逐字相同（统一 LF 后）。以提交为准，不以包版本推断实现。[fork 提交][K-COMMIT]、[fork player][K-LOCAL]。 |
| Windows 原生包 | 路径覆盖为 third_party 包，标称 1.0.10。CMake 固定 20260819 归档，mpv 提交前缀 e7191f2a65。 | 本地依据：[libmpv.cmake][L-CMAKE]。本次不下载归档。 |
| 本地 DLL 静态身份 | Profile 目录 DLL 的文件版本为 `v0.41.0-928-ge7191f2a6`；SHA256 与 CMake 固定值一致。 | SHA256：`7bda2cee77f00bd9be104c590055b44d2f9c5074de3a6b92f7f1e763fe2b3a6e`。只能证明这个磁盘文件。不能证明实验进程已加载它，也不能仅凭版本字符串排除下游补丁。[本地固定配置][L-CMAKE]。 |
| 本报告 mpv 依据 | 官方提交 `e7191f2a65d64af266c5c80793e79d2f4b92b789`。提交时间为 2026-08-17 17:57:13 UTC。 | 读取该提交的官方手册源文件和 C 源码。不是用最新 master 替代本地版本。[mpv 提交][M-COMMIT]、[固定版手册][M-MANUAL]。 |
| 官方 media_kit 对照 | 本次查询 main 的提交为 `c533e446755f51cf53c7e57aea873f2aa5355f81`。 | 只作 API 差异对照。不是本地依赖，也未证明是任何已发布包版本。上游 getProperty 返回 Future；本地 fork 返回同步 String。不能照搬上游初始化等待、释放和 observeProperty 行为。[上游固定源码][K-UPSTREAM]。 |
| Flutter | package_config 声明 Flutter 3.47.5、Dart 3.13.4。 | FrameTiming 官方网页按 2026-10-03 读取快照使用。未对本地引擎二进制逐项证明；尤其不保证批次投递间隔完全相同。[FrameTiming][F-TIMING]、[addTimingsCallback][F-CALLBACK]。 |

### 检索限制

已按要求调用 web.run：两次搜索 mpv/media_kit 官方主源，一次打开 [mpv 官方手册入口][M-LIVE]。均未返回可读结果。停止同方向重试。改用 GitHub 连接器和 PowerShell HTTPS 读取官方固定版本文件。所有远程正文只保存在内存。Node 原生 fetch 失败，未据此认定网站不可访问。GitHub API 补读上游提交日期时返回 403；该日期未验证。本报告不声称已完整审阅当前最新 master。

## 2. 属性语义

| 属性 | 实际代表什么 | 空值与解释边界 | 第一方证据 |
| --- | --- | --- | --- |
| `hwdec-current` | 当前视频解码器实际采用的硬解方式。`no` 明确代表软件解码。它不同于请求选项 `hwdec`。 | 无解码器时不可用。空串/null 不等于 no。非 no 也不能证明零拷贝、GPU 利用率、呈现效率或整个渲染链均为硬件路径。 | [手册][M-HW]、[属性实现][C-HW]。 |
| `video-format` | 本固定版本将它别名映射到 `current-tracks/video/codec`，是所选视频轨的编码名，例如 h264。 | 不是像素格式，也不是容器类型。不要把它解释为 nv12/yuv420p。无所选轨或元数据缺失时可能不可用。 | [别名注册][C-ALIASES]、[轨道编码字段][M-CODEC]、[当前轨道][M-TRACK]。 |
| `video-codec` | 别名映射到 `current-tracks/video/codec-desc`，是编码器描述名。 | 不是硬解后端，也不等于解码器已成功持续产出视频帧。像素格式应另看 video-params/pixelformat 或对应输出参数。 | [别名注册][C-ALIASES]、[轨道说明][M-CODEC]、[视频参数][M-PIXEL]。 |
| `estimated-vf-fps` | 手册定义为视频滤镜链输出的估计 FPS；无滤镜时对应解码输出。固定代码取历史近似帧时长的倒数。 | 无视频链、无有效正帧时长时不可用。丢帧、精确 seek、时间戳抖动会使估计不稳。不是 Flutter FPS，也不是按墙钟时间计算的解码吞吐率；暂停后的非零值可以是历史值。 | [手册][M-FPS]、[getter][C-FPS]、[时长计算][C-VIDEO]。 |
| `decoder-frame-drop-count` | 解码侧估计丢弃帧数。手册主要关联 framedrop=decoder 下视频落后于音频；损坏包或特殊解码器也可能影响它。 | 无当前视频解码器时不可用。0 只说明这个计数未记到丢帧，不能证明没有 UI 卡顿或所有应有帧都已呈现。源码按“无输出的包数”估计部分丢弃量，不是最终屏幕帧审计。 | [手册][M-DROP]、[属性绑定][C-DROP]、[计数更新][C-DEC-UPDATE]。 |
| `frame-drop-count` | mpv 视频输出（VO）的丢帧计数。与解码侧计数不同。 | 无视频链时不可用。libmpv VO 在 render API 用户过慢、下一帧未被消费时也会递增；不能只按 framedrop=vo 的选项值解释。不是 Windows 桌面最终呈现丢帧数。 | [手册][M-DROP]、[VO getter][C-VO-GET]、[libmpv 超时处理][C-LIBMPV]。 |
| `demuxer-cache-duration` | 解复用缓存的近似前向时长，单位秒。 | 手册明确称估计不可靠；缓存有数据时也可能不可用。不是已解码帧时长、弹幕缓存时长、字节数或 RSS。固定源码以解码读取位置与缓存末端时间戳估算，并选择各流类型中的较短有效时长；不能只当作视频单流数据。 | [手册][M-CACHE]、[reader state][C-READER]。 |
| `demuxer-cache-time` | 缓存末端的近似媒体时间戳，单位秒。 | 不是“还有多少秒”。固定源码直接返回 reader state 的 end。它与 duration 的起点是解复用读取位置，不必等于播放呈现位置 time-pos。 | [手册][M-CACHE]、[getter][C-CACHE]、[reader state][C-READER]。 |
| 裸 `cache-time` | 本固定属性注册表没有这个名称；若只是简称，应明确写为 demuxer-cache-time。 | 未证明其他版本或业务包装是否另有映射。不得直接查询后把空值变成 0。cache-end/cache-duration 是 demuxer-cache-state 的成员名，不等于裸 cache-time。 | [基础属性注册表][C-REGISTRY]、[缓存节点说明][M-CACHE]。 |
| `video-bitrate` / `audio-bitrate` | 根据选中流的压缩包大小与包时间戳跨度估算的历史码率。原始数值单位 bit/s。OSD 格式可能换成 kbps/Mbps。 | 不是下载速率、解码速度、GPU/Flutter 工作量或实时带宽需求。视频主要随关键帧更新。VBR、时间戳和解复用改包会影响值。无有效流统计、刚 seek 或不足有效时间跨度时可能不可用。 | [手册][M-BITRATE]、[bit/s 换算][C-BITRATE]、[包级更新][C-BR-UPDATE]、[统计 getter][C-BR-GET]。 |

### FPS 手册与源码存在窗口差异

固定手册仍写“最近 10 个帧时长”。同一提交的 calc_average_frame_duration 实际遍历有效的 past_frames；数组上限 MAX_NUM_VO_PTS 为 100。报告以这个差异为事实，不承诺固定 10 帧窗口，也不把该字段用作精确掉帧率分母。[固定手册][M-FPS]、[平均实现][C-VIDEO]、[历史上限][C-CORE]。

### 码率与缓存不能互换

1. 固定实现使用包的 DTS 优先、PTS 回退，并在关键帧与至少 0.5 秒时间戳跨度后更新码率。这是媒体时间，不是采样器墙钟时间；getter 不重新计算一秒下载量。播放 speed 变化不直接改变此码率含义。[包级更新][C-BR-UPDATE]、[统计 getter][C-BR-GET]、[手册][M-BITRATE]。
2. demuxer-cache-state/raw-input-rate 和 cache-speed 才是字节输入层的估计速率，单位 byte/s；也可能不准或缺失。它们仍不是整个应用全部连接的网络流量。[输入速率定义][M-INPUT]、[缓存节点][M-CACHE]。
3. duration × bitrate / 8 最多是粗略推测，不能作为缓存内存证明。它忽略 VBR、回看缓存、音频/字幕、包元数据、不同 demuxer 和磁盘缓存；也不能与弹幕缓存账面值或进程 RSS 建立恒等式。[缓存节点][M-CACHE]、[缓存选项][M-OPTIONS-CACHE]、[码率][M-BITRATE]。
4. 如需解复用缓存字节趋势，可选 demuxer-cache-state/fw-bytes；它是当前读取位置之后的压缩包字节粗估，忽略部分开销，不等于全部缓存、应用缓存预算或 RSS。file-cache-bytes 则表示磁盘缓存文件占用，不是 RAM。[缓存节点][M-CACHE]。

## 3. 本地 media_kit 映射与空值

### 现有 bufferMs 不是剩余缓存

本地 fork 观察 demuxer-cache-time，并把该值乘 1e6 转为 Duration，直接保存到 state.buffer。因此现有诊断的 bufferMs 是“缓存末端时间戳毫秒”，不是剩余缓存时长。将其重命名解释为 cacheEndMs 更清晰；本报告不修改代码。[fork 映射][K-BUFFER]、[mpv 定义][M-CACHE]。

代码仅在事件格式为 MPV_FORMAT_DOUBLE 时更新 buffer。遇到 MPV_FORMAT_NONE 时没有在该分支清空旧值。由此可推断：单看 Dart state.buffer 不能证明最新原生值有效；初始化的 0 与真正缓存末端 0 也无法区分。采样应带可用性和新鲜度，而非直接认定“缓存已空”。[fork 映射][K-BUFFER]、[事件格式契约][A-OBSERVE]。

### NULL、空串、no、0 必须分开

- mpv_get_property_string 在读取失败时返回 NULL；它丢失细分错误。要区分未初始化、属性不存在、暂不可用和格式错误，应使用 mpv_get_property 的返回码及适合的类型。[client API][A-GET]。
- 本地 fork getProperty 把 NULL 变成空串。仅凭空串不能判断根因。它不是软解标记，不是 0，也不证明无缓存。[fork getter][K-LOCAL]、[client API][A-GET]。
- 本地 fork 的失败分支未释放名称内存。高频读取不可用属性可累积这项泄漏。官方上游对照版本已用 finally 释放名称；此修复不能假定已存在于本地 fork。[本地 getter][K-LOCAL]、[上游对照][K-UPSTREAM]。
- 本仓库 PlayerDiagnostics._property 在 finally 中释放名称，释放成功结果，并以 null 保留失败状态。它规避上述失败路径泄漏，但仍不保留细分错误码。[本地诊断文件][L-PLAYER]、[API 分配契约][A-GET]。
- 原生属性不可用应保留 null/available=false；不要补 0。属性值明确为 no、整数 0 或真实空字符串时，语义与失败不同。[属性契约][A-GET]、[hwdec 定义][M-HW]。

## 4. 读取是否干扰播放器

**已证明：读取这些计数不会清零，不会主动 seek，也不会设置 pause。未证明：读取开销为零或不会影响本机慢帧。**

1. 本地 getProperty 和诊断包装均调用同步 FFI。mpv_get_property 经 run_locked 获取核心 dispatch 锁后运行 getter。API 文档明确说明同步调用会等待核心就绪，等待时间不受统一上限保证。它可能占用 Dart UI isolate 时间，并与播放核心竞争调度。[fork getter][K-LOCAL]、[读取调用路径][A-GET-IMPL]、[核心锁实现][A-SYNC-IMPL]、[同步契约][A-SYNC]。
2. decoder/VO 计数 getter 只在锁内读取，没有读后清零。码率 getter 在 demux 锁内汇总已有统计。缓存 reader state 在 demux 锁内遍历流。低频读不等于无锁读；成本与播放器状态有关。[解码 getter][C-DEC-GET]、[VO getter][C-VO-GET]、[码率 getter][C-BR-GET]、[reader state][C-READER]。
3. 不要从 mpv render 回调或渲染线程执行普通同步 client API。官方 render 契约警告此类依赖可引起超时或死锁。异步 API 仅解决调用方等待，不等于整体工作量消失。[渲染线程契约][A-RENDER]、[异步 API][A-GET]。
4. 多个顺序 getter 不是原子快照。字段间可能跨越 seek、切轨或回退。应记录一组读取的开始、结束和耗时；跨状态变化的样本不用于严格差值。这是由逐次核心锁读取推得的采样限制。[同步实现][A-SYNC-IMPL]。
5. observe_property 可减少业务定时重复调用，但它有事件、核心取值和转换成本。事件会合并；不保证每次变化都通知。不可用时可得到 MPV_FORMAT_NONE。不要当成逐帧真值流，也不要未经对照就声称它总比 1 Hz 读取更便宜。[观察契约][A-OBSERVE]。
6. 本地 fork 已内部观察 pause、time-pos、core-idle、paused-for-cache、demuxer-cache-time 等字段。优先复用现有 Dart 状态，避免重复订阅。本次未证明该 fork 存在上游对照中的公开 observeProperty API。[本地初始化][K-OBSERVED]、[上游 API][K-UPSTREAM]。
7. 所有读取只限有效播放器生命周期。注销采样后再释放句柄。Dart try/catch 不能作为失效原生指针的安全保证。现有诊断检查 disposed 并注销注册；本次只核对源码，未做生命周期压力实验。[本地诊断][L-PLAYER]、[client API][A-GET]。

**建议频率（未实测最优）：** 主组 1 Hz；稳定配置与字符串每次状态变更读取，必要时 5 秒复核；扩展 cache-state/码率最多 5 秒一次。无需逐帧或 250 ms 轮询全部原生属性。两组实验必须使用完全相同的采样字段、周期、日志级别与落盘方式；读取耗时和实际采样间隔要随样本保存。

## 5. pause 与 seek 的统计边界

| 状态 | 已证明或合理推断 | 实验处理建议 |
| --- | --- | --- |
| 普通 pause/resume | 固定 pause 状态路径不重置上述两类计数，也不清空 FPS 历史。fork 在 pause 方法中先更新 playing=false，再设置原生 pause。因此某个 Dart 状态值并非所有原生字段同刻的确认。[暂停实现][C-PAUSE]、[fork pause][K-PAUSE]。 | 暂停区间另分段。暂停前后不能用总墙钟时长当有效播放分母。稳态里保留最后值不等于继续产出帧。 |
| 暂停期间的缓存/码率 | 普通 pause 路径未要求清空 demux 队列；缓存继续填充或码率暂留旧值是合理推断，不是本机验证结果。预读取受缓存上限控制。[暂停路径][C-PAUSE]、[缓存选项][M-OPTIONS-CACHE]、[包级码率更新][C-BR-UPDATE]。 | 不把暂停中缓存变化或保持非零 FPS/码率认定为异常；不得假定缓存一定增长。 |
| 正常 seek | mp_seek 调用 reset_playback_state；filter reset 会重置解码侧 dropped_frames；video reset 调用 vo_seek_reset，后者清零 VO drop_count。FPS 历史也清空。[seek/reset][C-SEEK]、[解码重置][C-DEC-RESET]、[视频重置][C-VIDEO-RESET]、[VO 重置][C-VO-RESET]、[VO reset 调用][C-VO-GET]。 | seek 后重新建立计数基线。不跨 seek 求差；计数下降是重置信号，不是负丢帧。 |
| seek 后码率/缓存 | demux 读取状态重置会令 bitrate 无效；后续有效关键帧跨度才能形成新估计。缓存范围、end、duration 可跳变；暂停中的 seek 也不能当作稳定暂停样本。[demux 重置][C-BR-RESET]、[包级更新][C-BR-UPDATE]、[缓存定义][M-CACHE]。 | 先结束 seeking，再等 playback-restart 和预定预热段；码率仍可能暂不可用，不强制填 0。 |
| 自动重启、换轨、回退、重新打开文件 | seeking 也可表示装载/重同步；seek 事件可由内部触发。不能只靠用户操作日志判断连续性。[状态定义][M-STATE]、[事件定义][M-EVENTS]。 | 这些变化新建 epoch/分段；即使计数未下降也不跨解码器/VO 世代比较。 |

建议差值规则：只有同一分段、两个样本均有效、无 seek/reconfig、计数非下降时，才计算 current - previous。其他情况标记 reset/unknown 并重新取基线。不要使用 max(0, delta) 隐藏重置。若报告“每秒计数”，分母使用有效播放段的实际单调时长，并说明它仍不是“丢帧比例”。

fork seek 发送 absolute seek，不附带 exact 标志；真正精度还取决于 mpv 选项。不能将 Future 完成视作视频已经稳定恢复。seek/seeking/playback-restart 应单独记录。[fork seek][K-SEEK]、[官方事件][M-EVENTS]。

## 6. 不能等同 Flutter 慢帧

- Flutter FrameTiming.buildDuration 是 UI 构建时间；rasterDuration 是光栅线程时间。超过显示器帧预算是 Flutter 性能指标，不是媒体帧计数。[FrameTiming][F-TIMING]、[慢帧预算说明][F-CALLBACK]。
- 本仓库 slowFrames 按 build 或 raster 任一超预算计数；每次 capture 后窗口归零。mpv 两类丢帧计数则在自身解码器/VO 重置边界清零。二者连“累计窗口”都不同。[本地实现][L-DIAGNOSTICS]、[解码重置][C-DEC-RESET]、[VO 重置][C-VO-RESET]。
- Windows fork 的链路为 mpv 更新回调 → 插件线程池执行 mpv render/表面更新 → MarkTextureFrameAvailable → Flutter。通知纹理可用不等于这帧已经在桌面呈现；此文件未调用 mpv_render_context_report_swap。只能推断缺少这条最终 swap 回传，不能由 VO 计数审计桌面全部掉帧。[Windows 插件][K-WINDOWS]、[libmpv swap/timeout 路径][C-LIBMPV]。
- libmpv 的 render 等待超时处理能使 VO 丢帧增加。因此 UI/渲染阻塞可能间接影响 mpv；两条曲线相关不证明因果，更不建立 1:1 对应。decoder drop、VO drop、Flutter slowFrames 应并列保存，禁止相加成“总掉帧”。[libmpv 实现][C-LIBMPV]、[FrameTiming][F-TIMING]。
- FrameTiming 通知按批次投递，未必与定时采样窗口对齐。按收到回调的时间分桶只适合近似窗口相关分析；不应把同一行数字解释成同刻发生。若按帧时间戳对齐，还须验证它与实验单调时钟的映射，不能直接减 UTC 时间。[回调投递][F-CALLBACK]、[时间戳契约][F-TIMING]。

## 7. 推荐低频采样字段

以下是后续实现建议，本次没有修改或新增采样代码。

类型建议：计数用 MPV_FORMAT_INT64，秒/FPS/码率用 MPV_FORMAT_DOUBLE，状态用 MPV_FORMAT_FLAG，名称用 MPV_FORMAT_STRING；同时保存返回码。格式与属性不兼容时可能失败，必须保留错误，不能以零覆盖。[类型与错误契约][A-GET]、[错误分类][A-ERROR]。

| 组 | 字段 | 建议频率与限制 |
| --- | --- | --- |
| 会话身份 | mpv-version、ffmpeg-version、已验证 DLL 指纹、Dart fork SHA、构建模式、Flutter 版本、显示刷新率 | 初始化有效后一次。原生读取失败需保留 unknown，不能永久当作已确认版本。磁盘 DLL 身份不能代替实际加载身份。[API][A-GET]。 |
| 状态/时间 | 单调采样起止、实际间隔、读取耗时；position、speed、playing、buffering；pause、core-idle、paused-for-cache、seeking；分段编号 | 1 Hz；优先复用已有状态。状态或生命周期变化追加分段事件。core-idle 与 pause 可不同，buffering=false 不足以证明稳态播放。[状态定义][M-STATE]、[内部观察][K-OBSERVED]、[fork pause][K-PAUSE]。 |
| 两类媒体计数 | decoder-frame-drop-count、frame-drop-count 及各自可用性 | 1 Hz 原始累计值；在同一分段内计算差值。[计数 getter][C-DROP]。 |
| FPS 与缓存 | estimated-vf-fps、demuxer-cache-duration、demuxer-cache-time | 1 Hz；明确是估计值。现有 bufferMs 如被复用必须标注 cacheEndMs，不能冒充 duration。[FPS][M-FPS]、[缓存][M-CACHE]、[fork 映射][K-BUFFER]。 |
| 配置与轨道 | 请求 hwdec、实际 hwdec-current、video-format、video-codec、视频尺寸；必要时记录 framedrop、video-sync、vf、缓存配置 | 开始/切轨/回退后读取；需要捕获隐式变化时 5 秒复核。请求与实际必须分列。[hwdec][M-HW]、[编码别名][C-ALIASES]、[framedrop][M-OPTIONS-DROP]。 |
| 可选扩展 | video-bitrate、audio-bitrate；fw-bytes、raw-input-rate，必要时音视频各自 ts-per-stream | 5 秒。保持 bit/s 与 byte/s 分离。只记录白名单标量，不保存整份 track-list、metadata 或网络信息。[码率][M-BITRATE]、[缓存节点][M-CACHE]。 |
| Flutter 侧 | count、slowFrames、average/max build/raster 时间；固定刷新预算 | 继续使用已有 FrameTiming 聚合。注明这是 Flutter 窗口统计，独立于 mpv 累计值。[官方指标][F-TIMING]、[本地聚合][L-DIAGNOSTICS]。 |

### 禁止由这些字段直接推断

1. hwdec-current → GPU 占用、GPU 内存、零拷贝或硬解收益百分比。
2. estimated-vf-fps → Flutter FPS、解码吞吐率、最终桌面帧率或丢帧比例分母。
3. decoder/VO drop → Flutter slowFrames；任一计数为 0 → 全链路无卡顿。
4. video/audio-bitrate → 下载带宽、业务声明码率、CPU/GPU 负荷。
5. cache duration/end → 真实缓存内存、剩余可播放时长保证、弹幕缓存预算。
6. bufferMs、空串/null 或默认 0 → 最新缓存状态或明确软解。
7. 暂停/seek 两端差值 → 稳态连续播放性能。
8. 磁盘 DLL 版本/哈希 → 实验进程的已加载版本。

以上限制分别由属性定义、层次分离和本地包装行为推出；不是缺少采样频率就能消除的限制。[hwdec][M-HW]、[FPS][M-FPS]、[丢帧][M-DROP]、[码率][M-BITRATE]、[缓存][M-CACHE]、[fork getter][K-LOCAL]、[Windows 渲染][K-WINDOWS]。

## 8. 真实播放实验的最低控制条件

以下只给控制条件，不执行主代理的预算或生命周期实验。

1. **固定实际运行身份。** 使用同一二进制与构建模式；记录运行时 mpv-version/ffmpeg-version、Dart fork SHA。实际加载 DLL 身份由主代理核对，不能拿本报告的磁盘静态身份代替。
2. **使用 profile 或 release 比较。** 同组一致。Flutter 官方明确提醒 debug 指标可能因调试开销显著不同。[FrameTiming][F-TIMING]。
3. **固定媒体和输出条件。** 内部用不含媒体定位信息的实验编号；固定同一内容段、轨道、编码、分辨率、目标时长、speed、窗口大小、刷新率、音频输出及视频同步方式。文档中不保存媒体 URL、文件名中的个人信息或账号标识。
4. **固定解码与丢帧策略。** 同一 requested hwdec、framedrop、video-sync、滤镜；先确认 hwdec-current，并监控实际回退。未启用解码丢帧时，其计数为 0 不能用于论证解码性能优良。[hwdec][M-HW]、[framedrop][M-OPTIONS-DROP]。
5. **固定缓存与网络条件。** 记录 cache、cache-secs、demuxer-max-bytes/max-back-bytes、cache-on-disk、demuxer-readahead-secs、cache-pause 及初始缓存冷热状态。网络播放至少区分缓冲停顿段和正常段，不用 bitrate 证明两组网络等价。[缓存选项][M-OPTIONS-CACHE]、[码率][M-BITRATE]。
6. **明确预热与稳态窗口。** 新开文件、seek、切轨、回退、窗口/渲染重建后重新分段。等待 playback-restart，确认 seeking=false、非 cache pause，再执行相同预热规则。使用窗口长度和采样有效率，不随意丢弃“不好看”的样本。[状态][M-STATE]、[事件][M-EVENTS]。
7. **保持被测因素以外的负载一致。** 同一弹幕数据集编号与内容时段；相同可见性、字体/密度/速度、后台任务与电源策略。只改变本轮指定变量；这里不制定或复做主代理的缓存预算实验。
8. **保持观察者一致。** 相同字段、周期、日志等级、写盘和界面更新方式。禁止某组额外开 verbose、逐帧输出或截图。保存取样耗时、有效样本数和实际间隔；如需验证取样扰动，由主代理另做采样开/关对照。本次没有该对照结果。[同步 API][A-SYNC]、[观察 API][A-OBSERVE]。
9. **正确归零与结算。** 每个稳态分段独立建立两个原生计数基线；Flutter 窗口单独统计。结束前给 FrameTiming 批次投递留出统一结算规则；不把异步回调交付时刻当作帧发生时刻。[重置][C-SEEK]、[回调投递][F-CALLBACK]。
10. **生命周期与隐私。** 释放播放器前先注销读数；不保留失效句柄。不记录媒体 URL、弹幕原文、个人标识、凭据；也不导出完整轨道、元数据或原生日志文本作为默认遥测字段。

## 9. 未验证项与交付检查

- 未验证实验进程实际加载 DLL、实际硬解方式、运行时属性可用率、真实重置时刻、下游原生补丁以及取样开销大小。
- 未测真实弹幕预算、内存、生命周期、Flutter 卡顿或播放性能。没有将静态语义证明写成实验结果。
- 当前仓库已有诊断源码会随主代理工作变化；本报告对本次读到的包装有效，不锁定将来的实现。
- 只创建本报告。未安装依赖、构建、基准、暂存、提交或修改生产/测试源码。
- 核心验收已覆盖：全部指定属性；同步取样、失败值、pause/seek 重置；码率/缓存层次；Flutter 不等价；低频字段与最低控制条件。

## 第一方 URL 索引

官方 mpv 手册使用同提交的 input.rst 源文件。下列链接均锁定提交，除明确标为实时入口或未版本化 Flutter 文档者。

[M-LIVE]: https://mpv.io/manual/master/
[M-COMMIT]: https://github.com/mpv-player/mpv/commit/e7191f2a65d64af266c5c80793e79d2f4b92b789
[M-MANUAL]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/input.rst
[M-HW]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/input.rst#L2776-L2779
[M-DROP]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/input.rst#L2303-L2310
[M-FPS]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/input.rst#L3024-L3030
[M-CACHE]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/input.rst#L2564-L2623
[M-BITRATE]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/input.rst#L3890-L3912
[M-CODEC]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/input.rst#L3545-L3550
[M-TRACK]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/input.rst#L3705-L3716
[M-PIXEL]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/input.rst#L2801-L2822
[M-INPUT]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/input.rst#L2548-L2562
[M-STATE]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/input.rst#L2548-L2695
[M-EVENTS]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/input.rst#L1870-L1879
[M-OPTIONS-CACHE]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/options.rst#L4250-L5568
[M-OPTIONS-DROP]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/DOCS/man/options.rst#L1245-L1285
[C-HW]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/command.c#L2382-L2395
[C-ALIASES]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/command.c#L4708-L4727
[C-FPS]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/command.c#L3328-L3337
[C-DROP]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/command.c#L751-L804
[C-CACHE]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/command.c#L1517-L1546
[C-BITRATE]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/command.c#L3785-L3818
[C-REGISTRY]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/command.c#L4599-L4815
[C-READER]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/demux/demux.c#L4645-L4708
[C-BR-UPDATE]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/demux/demux.c#L2829-L2849
[C-BR-GET]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/demux/demux.c#L4627-L4643
[C-BR-RESET]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/demux/demux.c#L824-L831
[C-DEC-RESET]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/filters/f_decoder_wrapper.c#L333-L355
[C-DEC-GET]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/filters/f_decoder_wrapper.c#L534-L540
[C-DEC-UPDATE]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/filters/f_decoder_wrapper.c#L1071-L1077
[C-VO-RESET]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/video/out/vo.c#L695-L710
[C-VO-GET]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/video/out/vo.c#L1243-L1288
[C-VIDEO-RESET]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/video.c#L91-L126
[C-VIDEO]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/video.c#L668-L679
[C-CORE]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/core.h#L59-L66
[C-LIBMPV]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/video/out/vo_libmpv.c#L429-L554
[C-PAUSE]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/playloop.c#L164-L198
[C-SEEK]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/playloop.c#L240-L405
[A-GET]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/include/mpv/client.h#L1114-L1176
[A-ERROR]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/include/mpv/client.h#L298-L339
[A-GET-IMPL]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/client.c#L1473-L1497
[A-SYNC]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/include/mpv/client.h#L99-L138
[A-SYNC-IMPL]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/player/client.c#L1061-L1065
[A-OBSERVE]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/include/mpv/client.h#L1178-L1228
[A-RENDER]: https://github.com/mpv-player/mpv/blob/e7191f2a65d64af266c5c80793e79d2f4b92b789/include/mpv/render.h#L32-L85
[K-COMMIT]: https://github.com/My-Responsitories/media-kit/commit/73771ec38176be2d984a3049c28177bce23b54a0
[K-LOCAL]: https://github.com/My-Responsitories/media-kit/blob/73771ec38176be2d984a3049c28177bce23b54a0/media_kit/lib/src/player/native/player/real.dart#L956-L971
[K-BUFFER]: https://github.com/My-Responsitories/media-kit/blob/73771ec38176be2d984a3049c28177bce23b54a0/media_kit/lib/src/player/native/player/real.dart#L1081-L1090
[K-OBSERVED]: https://github.com/My-Responsitories/media-kit/blob/73771ec38176be2d984a3049c28177bce23b54a0/media_kit/lib/src/player/native/player/real.dart#L1670-L1696
[K-PAUSE]: https://github.com/My-Responsitories/media-kit/blob/73771ec38176be2d984a3049c28177bce23b54a0/media_kit/lib/src/player/native/player/real.dart#L349-L360
[K-SEEK]: https://github.com/My-Responsitories/media-kit/blob/73771ec38176be2d984a3049c28177bce23b54a0/media_kit/lib/src/player/native/player/real.dart#L580-L602
[K-UPSTREAM]: https://github.com/media-kit/media-kit/blob/c533e446755f51cf53c7e57aea873f2aa5355f81/media_kit/lib/src/player/native/player/real.dart#L1264-L1331
[K-WINDOWS]: https://github.com/My-Responsitories/media-kit/blob/73771ec38176be2d984a3049c28177bce23b54a0/media_kit_video/windows/video_output.cc
[F-TIMING]: https://api.flutter.dev/flutter/dart-ui/FrameTiming-class.html
[F-CALLBACK]: https://api.flutter.dev/flutter/scheduler/SchedulerBinding/addTimingsCallback.html
[L-CMAKE]: E:/Code/project/PiliAurora/third_party/media_kit_libs_windows_video/windows/libmpv.cmake
[L-PLAYER]: E:/Code/project/PiliAurora/lib/services/diagnostics/player_diagnostics.dart
[L-DIAGNOSTICS]: E:/Code/project/PiliAurora/lib/services/diagnostics/diagnostics.dart

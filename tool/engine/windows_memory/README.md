# Windows 图形内存诊断引擎

实验入口，仅用于区分 Skia 资源引用、可回收缓存与页保留，不用于发布。
它基于 `.fvmrc` 对应的固定引擎提交，保留隔离检出中的 Windows 平台补丁。

先按 `../windows_frame_pacing/README.md` 准备同模式隔离引擎，再运行：

```powershell
python tool/engine/windows_memory/build_memory_engine.py --root build/windows-engine --mode release
```

脚本检查固定提交、补丁是否可应用，冲突时保留已有源码并停止。首次保存原 DLL/PDB/身份到
`build/memory-engine/baseline/`，随后以 Ninja 增量编译；不会修改 FVM SDK 缓存。
输出目录中的 `engine-memory-identity.json` 单独记录实验补丁和完整已跟踪源码差分摘要，
不能使用原 `engine-identity.json` 将此 DLL 认作正式呈现引擎。

## 通道

`pili_aurora/graphics_memory` 使用 `JSONMethodCodec`，只在该诊断引擎存在：

- `sample({resources: true})`：读取 raster 和 IO 上下文，含递增 `sampleId`。
- `purge({context: 'raster'})` 或 `purge({context: 'io'})`：仅回收所选上下文未锁定的
  GPU 缓存，返回该上下文的 `before` 和回收后统计。不触发 Dart GC、不清图片缓存。
- `freeGpuResources({context: 'raster'})` 或 `freeGpuResources({context: 'io'})`：
  独立显式动作；必须指定且只允许 raster/io，缺省、非法 context 返回空回执。
  所选 `contexts[context]` 含 `before`、`after`、`actionDurationUs`、
  `action: 'freeGpuResources'`、`context`、`internalFlushAndSubmit: true` 和
  `cpuSyncRequested: false`，同时保留同级动作后计数以兼容原采样读取方式。
  固定 Skia API 内部先 `flushAndSubmit()`（默认 `GrSyncCpu::kNo`，不等待 CPU 同步），
  再重置 small-path atlas（非 optimize-size 构建）、释放 atlas/strike cache、
  drawing manager 的非 retain flush callbacks 与 path renderer，最后回收未锁定资源。
  它不直接 reset GL ProgramCache，不能据此判定程序缓存已清；也不是原 purge 的严格
  超集，原 purge 额外执行 purgeAsNeeded、purgeStaleBlobs 和 releaseUnlockedBackendObjects。
  不额外调用手工 flush、GC、Trim、ImageCache/RasterCache clear 或强制应用帧。
  raster 仍检查 MakeRenderContextCurrent；IO 使用固定 Windows embedder 在资源上下文
  创建时 make_resource_current 成功后保持在该 IO 线程的现有 current context。
  API 已执行只代表发出动作，不能保证 GPU 已完成或驱动归还页；须动作后等待再采集。
- `purge({context: 'rasterCache'})`：只清除 Flutter RasterCache 的图片/图层引用，
  不同时回收 Skia 缓存；返回清理前的缓存估算，便于与下一步 raster purge 分开解释。
- `purge({context: 'flushIO'})` 或 `purge({context: 'flushRaster'})`：只对指定上下文
  执行 `flushAndSubmit(GrSyncCpu::kYes)`，提交并等待 GPU 完成；不显式执行 purge、GC
  或 RasterCache clear。该同步动作仅用于诊断，不应作为逐帧行为。
- 不支持的方法、非法参数返回空回执（MissingPlugin），避免永不完成的 Future。

两个上下文分别在对应线程采样，经异步任务串联，不在 UI/平台线程等待。
raster 操作检查 `MakeRenderContextCurrent`，IO 使用该线程已有的资源加载上下文。
GPU 已禁用时跳过操作；Surface/上下文不存在时明确标记 `available: false`。

通道 schemaVersion 为 **2**。每个上下文包含 `resourceCount/resourceBytes`，来源是
`skia/gpu_resources/resource_*` 资源 dump 子项，不计 GrDirectContext 的 cache 汇总行；
`resources: false` 时仍完整计总量，只是不保留详情。`budgetedResourceCount/Bytes` 单独
对应本版 Skia `getResourceCacheUsage`（该 API 实际只计 budgeted）；另外提供
`budgetBytes/purgeableBytes`，raster 额外包含
`rasterCacheLayerBytes/rasterCachePictureBytes`。资源详情保留 Skia 匿名 ID、类型、类别、
尺寸估计、可回收字节、wrapped 状态和 GL 整数 backing 名，不输出 label 或 CPU 地址。
最多返回64个最大候选条目；内部候选最多4096，超出时记录 `candidateLimitReached`。
`omittedEntries` 与总量允许消费者发现不完整详情，汇总仍来自原生上下文计数器。

这些字节是 Skia 名义资源尺寸，不是驱动的实际提交或驻留。两个上下文可能共享同一
GL backing，**不能直接相加**；同一资源也可在 texture/render target 子项中分列。
快照间 ID 消失只证明该 Skia 资源不再出现在上下文账本，不证明驱动已归还对应提交页。
采样并非两个线程同一时刻的原子快照。

旧 schemaVersion=1 的 `resourceCount/Bytes` 只计 budgeted，`dumpEntry*` 又包含一个
DirectContext cache 汇总行；解释旧日志时须使用资源列表和这个口径限制，不能直接当作
全部资源已归零。合成探针对 v2 DLL 的运行验证保存在独立记录中，不自动验证后续重建。

## 设备内部缓冲对照

独立通道 `pili_aurora/graphics_device` 同样使用 `JSONMethodCodec`，仅支持 `trim`。
收到显式请求后，在 Windows embedder 的 platform 消息回调检查当前线程，取得
`egl_manager_->GetDevice` 返回的真实 Flutter D3D11 设备，通过 `IDXGIDevice3` 执行 `Trim`。
不创建新设备、不调用 `ClearState`，不隐式 flush、purge、GC 或改设备线程保护。
为避免与 raster/IO 线程争用不支持并发的设备，带 `D3D11_CREATE_DEVICE_SINGLETHREADED`
标志时返回 `unsupported`，也不尝试绕过。

回执包含 `status`（trimmed/unsupported/failed）、`reason`、QI 的 `hresult`、
`durationUs`、设备创建 flags、当前是否 platform 线程以及 `trimIssued`。
`Trim` 本身无返回值，`trimmed` 只表示已发出回收提示，不保证驱动实际归还页或字节数。
应结合调用前后同进程的 VirtualQuery/Private 采样判断结果，不能把它当作资源泄漏证明。
设备恢复渲染可能重建内部缓冲，因此仅用于独立实验；普通 sample 绝不触发 Trim。

[windows-memory.patch](../../../doc/development/engine-patches/windows-memory.patch) 的 Windows 段相对于已应用 [windows-frame-pacing.patch](../../../doc/development/engine-patches/windows-frame-pacing.patch) 的源码
生成，只新增内存实验通道；不会重复应用或覆盖平台补丁。构建前原源码快照位于本地
`build/memory-engine/windows-engine-platform-pre-memory.cc`。

`graphics_device.sample` 是只读观察：返回 `idleTrim` 中的支持状态、成功呈现次数、
自动 Trim 的 attempts/issued、最后呈现/Trim 距今毫秒数、最后回收耗时微秒和 timer 状态。
尚无对应事件时年龄或耗时为 -1。读取各独立原子字段，不保证整条记录同一时刻原子一致；
普通 sample 不调用 Trim，也不重新计时或更改回收截止时间。显式 `trim` 不计入自动
issued，便于区分手动与自动实验。未编译自动策略或设备不支持时明确标记。

## 自动空闲回收实验

在诊断引擎上追加独立的 [windows-idle-trim.patch](../../../doc/development/engine-patches/windows-idle-trim.patch)：

```powershell
python tool/engine/windows_memory/build_memory_engine.py --root build/windows-engine --mode release --idle-trim
```

`--idle-only` 可在未应用诊断补丁的原平台引擎上单独启用此策略；它不引入诊断通道。
脚本不会为切换模式删除已有源码，发现与所选模式冲突会停止。正式平台补丁和预编译
产物不由该入口更新。构建身份分别记录诊断和 idle 补丁、辅助头文件摘要与启用状态。

同一 engine 的所有 view 在成功 Present 后更新最后呈现时刻。raster 线程仅保留一个
10秒定时器；持续帧只延后截止时间，不为每一帧追加任务。全部 view 静止10秒后，对
真实 D3D11 设备执行一次 Trim；再次呈现才开始新周期。纯静止期间不反复回收。
这不触发强制重绘、图片缓存清空或 GC，不改变图形状态。

延时任务只捕获弱策略状态；Stop 先取消，再等 raster shutdown 后释放该状态。
策略只持有 COM 设备引用，不持有 engine/raw this，也不循环持有 runner。设备失效或
不支持多线程 D3D11 设备时停止/禁用。正在开始的 Trim 与 Stop 竞争时，设备 COM 引用
保证生命周期，Shutdown 仍需等待当前 raster 工作结束。

构建前通过已登记的 MSVC 环境编译并运行原生回归，覆盖持续1800帧不回收、静止只
回收一次、恢复新帧重启周期、双 view 共用时钟、Stop/重启/弱任务销毁及设备丢失。
调度回归不验证实际驱动回收量、首次恢复帧耗时或黑帧，仍需真实应用 A/B。

## VM 观测与显式回收对照

独立通道 `pili_aurora/vm_memory` 使用 `JSONMethodCodec`：

- `vmSample`：只读 root isolate group 的 old/new used、capacity、external 指标，单位字节。
- `collectDart`：显式调用公开 `Dart_NotifyLowMemory`。此固定 Dart 版本实现仅清除 VM
  page/zone 缓存，**不执行 GC**；回执 `requestedGc: false`。
- `collectDartFull`：显式调用公开 `Dart_NotifyDestroyed`，此固定版本通过
  `Heap::NotifyDestroyed` 执行 compact + CollectAllGarbage，并清 page cache；
  该诊断动作可能耗时，不用于普通采样或后台周期策略。

三种动作均延期到独立 UI task，并在 root isolate scope 内读取指标；对象已销毁时给出
unavailable 回执，不输出 isolate/group 地址。普通图形 sample 不触发任何 VM 回收。
回收操作返回 before、实际 API、durationUs 及操作后的同组指标；所有容量为零时明确
unavailable。Release 的 group metrics 在当前固定 VM 实现可用，但须以真实回执验证。

`newUsedBytes` 的 API 在该版本为避免 TLAB 数据竞争，实际返回 new capacity；
回执含 `newUsedSemantics: capacityProxy`，不能将其当作精确存活量。
external 是 VM 外部分配记账，不是 native 独占或驻留字节。只观测 root group，
不自动包含另建 isolate group；回收后的原生 finalizer/IO unref 仍可能异步执行，
须在动作之后等待并重新采集图形资源与进程页。

## CPU 缓存独立对照

CPU 通道在 UI task 中校验实际线程。Windows embedder 不提供普通 FML queue ID，
因此使用 TaskRunner 的线程回调，不能比较 MessageLoop 的 queue ID。

`pili_aurora/cpu_memory` 使用 `JSONMethodCodec`，无参数方法为：

- `sample`：只读取进程全局 CPU resource/font 缓存计数。
- `purgeResource`：只调用 `SkGraphics::PurgeResourceCache()`，包括 CPU 位图资源与全局
  raster image-filter 缓存；不调用字体、HarfBuzz 或 Gr 缓存回收。
- `purgeFont`：只调用 `SkGraphics::PurgeFontCache()`，包括全局 strike 与全局 typeface
  cache；不包含 DirectWrite FontMgr 自有 cache、段落缓存或 HarfBuzz。
- `purgeHarfBuzz`：只调用 `SkShapers::HB::PurgeCaches()`；不清 ParagraphCache 或
  FontCollection 的 face/variation maps。

方法均延期到独立 UI task，不进入 Dart isolate、不访问 GL/context、不触发 GC、Trim、
强制帧或图片 ImageCache 清理。缓存实现分别持锁，统计不是跨缓存的原子快照。
不支持的方法/无效请求正常返回空回执。停止后的 engine 返回 `unavailable`。

回执为 JSON codec `[Map]`：`schemaVersion:1`、递增 `sampleId`、`action`、`status`、
`thread:'ui'`、virtual `TaskRunner::RunsTasksOnCurrentThread()` 判断的 `uiThread`、
`actionDurationUs` 和包括采样的 `durationUs`。Windows embedder runner 的线程检查：
该 runner 的 FML queue id 为 kInvalid，必须使用 embedder 提供的真实线程回调，不能比较
MessageLoop queue id。`threadValidation` 标明所用判断。
`sample` 只有 `after`，三个 purge 还有 `before`；结构为：

```text
after.resource: usedBytes, limitBytes, count, dumpUsedBytes, singleAllocationLimitBytes
after.font: usedBytes, limitBytes, count, limitCount, typefaceLimitCount, coverage
after.harfBuzz: usedBytes:null, limitBytes:null, count:null, limitCount:100,
               metricsAvailable:false, limitSource, reason
```

resource count 来自 CPU dump 的 size/discardable_size 子项，拒绝 glyph/GPU 行；不保留
包含 CPU 地址的条目名或 backing。font used/count 仅为全局 strike 账本，不能当作所有
字体页之和。固定 Skia 的 HarfBuzz 公开 API 没有 used/count getter，因此返回 null；100
是本固定源码的条数上限，并非运行时测得的 count。`purged` 只表示已执行 API，不表示
实际归还给 OS 的字节量；native heap 与 Private 应分别在操作后等待采样。

## 图形探针验证

配套入口是 `tool/probes/windows/graphics_memory.dart`：独立生成/解码图片，依次绘制、
脱离 UI、显式释放自己的句柄，然后分别回收 raster 和 IO 缓存。普通 FVM 引擎应返回
不支持；装配本 DLL 后应得到两个上下文的资源详情。以真实探针报告确认运行行为，
合成小窗口的占用不能代替完整应用的内存与恢复帧验收。

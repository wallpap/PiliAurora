# 诊断与轻量内存归属

用户入口仍为“设置 → 日志与诊断 → 记录性能”。推荐 1 秒采样，开启后正常操作，
退出播放后继续记录约 90 秒，再导出。记录、停止和导出沿用现有多窗口协调与文件轮转，
不需要额外启动脚本或管理员权限。

## 采集与所有权

- `diagnostics.dart` 复用已读取的性能 sample 调用 `MemoryAttribution.observe`。
  归属快照每 5 秒一条，观测到阶段变化时补充一条；不增加平台轮询、GPU 同步或强制回收。
- `memory_attribution.dart` 按 player 诊断源及 runtimeId 观测播放、全屏、路由和离页。
  离页后在首次达到 5／30／90 秒的正常采样中生成对照。时刻为采样观测，短于采样间隔的
  操作可能遗漏；`afterCloseElapsedMs` 保存实际经过时间，不能把延迟回报当作准点采样。
- 原生 `native_memory_stats.h` 在创建、释放、加载交接和 Flutter 注销回执边界更新固定账本。
  每个存活输出使用进程内匿名 ownerId，runtimeId／loadId 标识其当前绑定，不表示每个资源
  都在该 load 新建。输出析构后删除明细，全局 created／released 继续累计。
- Flutter 纹理注册计数仅覆盖插件登记至收到注销回执，不证明引擎导入的 D3D 对象已经销毁。
  `ownerStatus=unsupported` 表示旧插件尚无输出明细，不能视为没有输出。
- 图像缓存、Image／Picture 句柄、插件输出、raster／IO 分别保留原有统计口径。
  名义字节、句柄、进程 Private、WC 和 GPU 内存可能重叠，不求和、不生成伪独占总量。

日常采集默认不取调用栈和图形资源明细。专用引擎可用时，可在构建时设置
`PILIAURORA_GRAPHICS_DETAILS=true` 请求资源详情；`PILIAURORA_GRAPHICS_STACKS=true`
控制已有句柄创建栈功能。普通引擎继续明确返回 unsupported，交换链、引擎实际导入、
解码器内部、驱动内部和 Dart 堆列入 unobserved。深入归因见
[Windows 图形诊断引擎](../../../tool/engine/windows_memory/README.md)。

## 数据协议与上限

`performance.jsonl` 新增 `type=memoryAttribution`、`schema=1` 的有界记录，包含与 sample
相同的 runId、processId、windowId、session 上下文；sequence 为归属记录独立递增序列。
`collectionUs` 仅测归属计算，不包括已有平台读取、脱敏、编码和写盘，不能代替帧性能验收。

`kind=snapshot` 含进程页、缓存年龄和 owners；`kind=stage` 含阶段、播放编号、基线、峰值及
Private／WC 相对基线的差。首条观测已经在播放时不虚构基线；新播放或并发播放介入后标记
interveningPlayback。源读取失败不生成虚假的离页；页扫描不完整时 WC／RW 保持 null。

应用内最多跟踪 8 个活动播放和 8 个待对照退出，超出写入 omittedActivePlayers／
omittedFollowUps；原生最多跟踪 8 个存活输出，omittedOwners 表示当前未覆盖数量，
全局资源总计不因明细容量不足而停止。账本只保存计数和值，不持有播放器、图片或原生资源。

导出在已有后台 isolate 中流式读取快照，生成 `memory-summary.json`。摘要按
runId＋PID＋session＋windowId 分组，最多 32 组、每组最新 64 条阶段；轮转文件不要求
按时间到达，溢出、损坏和未知状态均保留。摘要来自本次实际导出的历史文件，停止记录或
重启应用后仍能生成，不依赖当前 UI 的可变内存状态。没有新版归属记录时返回 notRecorded。
导出复制和脱敏仍遵守原协议，资源字典和每个输出分别限界，避免后面的 owner 被截掉。

## 验证

```powershell
fvm flutter test --no-pub test/services/diagnostics/ test/services/desktop_diagnostics_test.dart test/pages/about/diagnostics_page_test.dart
python -m unittest tool/probes/windows/native_memory_stats_test.py
python tool/probes/windows/windows_renderer_release_probe.py
```

`tool/experiments/diagnostics/memory_attribution_benchmark.dart` 可回放一个或多个解压目录，
统计新增归属计算时间和载荷大小。示例：

```powershell
fvm dart run tool/experiments/diagnostics/memory_attribution_benchmark.dart <解压目录>
```

真实设备仍需对照记录关闭／开启时的 CPU、帧时间、内存和写盘量。离线回放与原生账本
并发回归只验证这两个局部环节，不证明完整应用没有性能变化。

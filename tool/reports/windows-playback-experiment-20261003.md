# Windows 播放实验接手记录（2026-10-03）

> 本文记录上一轮结束时的状态。后续 runner 隔离修复及轨道拒绝研究见 [接手修复记录](windows-runner-repair-and-track-followup-20261003.md)；完整插件集的退出故障仍未验证解决。

## 状态

- 分支：`codex/windows-playback-experiments-20261003`。
- 起点：`d1593665d`。原主分支未修改、未合并、未推送。
- 本轮未完成 16 / 24 / 32 MiB 缓存对照，也未完成长时间生命周期实验。
- 原因：烟雾测试在完成测量后的 Windows 原生退出阶段失败。已停止启动播放器。
- **不能把测量文件已写出，解释为端到端测试通过。**

## 已固化的实验能力

原真实弹幕工具只保存在被忽略的 `build/`。新入口为：

`tool/danmaku_playback_benchmark.dart`

它支持：

1. 运行时指定本地视频、音频、弹幕、输出路径和缓存预算。同一构建可接受不同参数。
2. 使用播放器位置推进入场。暂停或 buffering 时停止弹幕。seek 后清空活动弹幕并重定位游标。
3. 记录真实 DPR。高级弹幕加载保护不再写死 1.5。
4. 基线 / prepared 路径和反转顺序。默认 prepared。
5. 预热、测量窗口、拒绝原因、栅格化、缓存淘汰、进程内存及 CPU 数据。
6. FrameTiming 批次收尾与时间戳裁剪，避免上一阶段的迟到帧污染下一阶段。
7. 生命周期流程：暂停、恢复、前后 seek、应用内视口尺寸变化、禁用 / 恢复弹幕、clear、缓存清空和 renderer dispose。
8. 明确区分测量完成与成功退出。最终只输出 `PLAYBACK_BENCH_READY`，不主动退出引擎。

注意：生命周期流程已经实现，**没有完成真实运行验证**。应用内视口变化不能替代系统 DPI 切换、多屏移动或真实窗口拖动。播放器位置校验允许一定的状态通知误差；它不是音画同步验证。

### 未改变的生产默认值

| 项目 | 默认 |
| --- | ---: |
| 活动图片账面预算 | 96 MiB，沿用起点提交 |
| 活动数量上限 | 600 |
| Raster Cache | 16 MiB |
| Cache 条目上限 | 512 |
| Windows 硬解请求 | 本轮未改变 |

缓存预算只新增创建时的注入参数。没有据此提高默认值。更换 Screen 缓存预算需要重建状态，不能在同一实例上动态更改。

`evictionsByBytes` / `evictionsByEntries` 新增了原因计数。两个条件同时超限时都计数，不能把两者相加解释为总淘汰数。

## 短烟雾样本：能确认什么

前三次普通烟雾测试使用同一份已下载的本地数据。原始 JSON 和日志保留在 `build/playback-20261003-*`，未纳入 Git。第四次调试器运行发生媒体位置停滞，排除性能分析。

| 条件 | 观察结果 |
| --- | --- |
| 视频 | AV1，1280 × 720 |
| 请求 / 实际硬解 | `auto-copy` / `d3d11va-copy` |
| mpv | `v0.41.0-928-ge7191f2a6` |
| DPR | 1.5 |
| 输出尺寸 | 1280 × 691 |
| 压力数据 | 17,499 条源元素，17,482 条可转换元素；仅记录数量，不提交正文 |
| 测量媒体区间 | 43.042 → 45.042 秒 |
| 测量长度 | 2 秒；之前预热 3 秒 |
| 采样 | 每 250 ms，8 个样本 |
| 测量期接受 / 拒绝 | 68 / 243 |
| mpv 两类 drop 计数 | 样本内均为 0 |
| 单次遥测平均同步耗时 | 约 261～379 μs |
| 累计 Cache 淘汰 | 532～539 次，字节压力计数相同，条目压力为 0 |

这些只证明采集字段与回放位置在前三个短窗口内可用。所有普通烟雾进程随后都退出失败，因此不能宣称稳定性通过。

当前 Cache 压力确实来自字节上限，而不是 512 个条目上限。但**没有 24 / 32 MiB 实测对照，不能宣称扩大 Cache 能提高性能**。

补充限制：

- 有非空 audio-bitrate，audio-codec 描述仍为空；不能因描述为空就断定没有音频。
- 已运行样本用 mpv audio-files 参数提供音频。最终工具改为与应用 FileSource 相同的 UTF-8 长度 EDL；这个最终媒体组合路径仅通过纯函数测试，尚未重新播放。
- 这些短样本不是在线点播、4K、音画同步、最终显示延迟或 GPU 时间线测试。
- 当前 native runner 的窗口显示行为与主应用初始化不同；输出尺寸和 FrameTiming 不等于实际可见屏幕的呈现审计。
- 活动图片与 Cache 是账面数据，存在共享图像 backing，不能相加当作独立物理内存或显存。
- 已保存样本中的部分拒绝计数包含 warmup；最终工具已改为窗口差分。这些不同版本计数不能直接混用。

## Windows 退出故障：确认事实与假设

### 运行记录

| 次序 | 改变的变量 | 结果 |
| --- | --- | --- |
| 1 | 测量结束后 `dart:io exit()` | 数据写出、纹理释放、打印完成标记；进程退出 `0xE0464645`，系统弹窗 |
| 2 | 改为 ServicesBinding 的框架退出 API | 数据写出；进程退出 `0xC000041D`，留下访问冲突转储 |
| 3 | 在窗口析构体显式 reset 控制器 | 仍以 `0xE0464645` 退出；不能判定修复 |
| 4 | 自建 Win32 调试器及仅本进程的错误模式 | 仍以 `0xE0464645` 退出；没有捕获解释该码的致命异常事件，用户仍见弹窗 |

两种主动退出都失败。调试器也没有解决问题，不能以“已经附加调试器”假定不会弹窗。

第三次的 runner 修改已撤回。自动批量启动脚本仅保存在忽略目录作为失败实验，不作为可用工具提交。工具不再调用 exit 或 exitApplication。**移除主动退出是风险控制，不是原生退出问题已经修复。**

### 已验证的转储内容

第二次的转储位于用户 CrashDumps 目录，未复制或提交完整转储。

- ExceptionRecord：`0xC0000005`。
- 异常地址：`flutter_windows.dll + 0x1e230`。
- 使用本机对应 Profile DLL 的 PDB 解析为 `FlutterWindowsView::GetEngine`。
- 栈地址候选涉及 `FlutterDesktopViewControllerHandleTopLevelWindowProc`、`FlutterWindowsViewController::Destroy` 及窗口销毁。
- Profile DLL 与 SDK DLL SHA256 一致：`81F9322FA80EA38CE53A90583D32D72657B53907F98CA3B8AB226FDECB0B0730`。

这是地址扫描与符号映射，不是完整展开的调用栈。它证明第二次访问冲突在 Flutter 视图生命周期附近，**不能据此确定其他三次 0xE0464645 的故障源**。

### WebView 的离线证据

本地锁定的 Windows WebView 源码提交为 `0bfa46dfff87f0d9e9d5e13cbd5c4a7c7310f8c9`，缓存工作树无改动。

- native plugin registrant 会注册 WebView 插件，即使基准没有 WebView 页面。
- 插件构造管理器；WinRT / 图形条件满足时创建 DispatcherQueue 与 Compositor。
- 管理器 header 将 rohelper、dispatcher_queue_controller、graphics_context、compositor 声明为 inline static。
- 管理器析构清理 WebView 容器，但没有显式释放上述静态资源。
- main.cpp 在函数作用域中的窗口对象析构之前调用 CoUninitialize。

第一方项目有一份相似报告，记录了 `0xE0464645`、Unknown Hard Error 和同名插件静态 Compositor 的 DLL 退出析构路径。[相似故障报告][EXIT-ISSUE]、[锁定 header][WEBVIEW-H]、[锁定 manager][WEBVIEW-CPP]、[锁定 plugin][WEBVIEW-PLUGIN]。

**合理推断：** WebView 的静态 COM / DispatcherQueue 释放顺序是下一项优先检查对象。

**未确认：** 本机 0xE0464645 的故障栈就是该路径。未做插件排除对照，也未验证依赖补丁。此前“FFI 回调导致”的解释没有足够证据，不能作为结论。

### Windows Error Reporting

只读查询确认：WerSvc 为 Stopped / Disabled。

相似报告指出，错误报告服务不可用时可能显示 Unknown Hard Error。这可能影响本机故障的展示与转储采集，但服务状态不是原始资源生命周期故障的修复。没有启用服务、修改注册表、权限或系统安全配置。[相似故障报告][EXIT-ISSUE]

## 遥测语义与内存保护

详见 `windows-playback-telemetry-semantics-20261003.md`。

- bufferMs 是缓存末端媒体时间戳，不是可播放剩余时长。
- video/audio-bitrate 是压缩流统计，不是网络下载速率。
- mpv drop 计数和 Flutter 慢帧属于不同层次，不能相加或等同。
- seek 后应重新建基线，不跨 seek 求累计计数差。
- getProperty 是同步 FFI，取样存在阻塞与扰动。
- 本地 fork 的 getProperty 失败路径漏释放名称；现有诊断包装已有正确的 finally。此次抽取为共享 readMpvProperty，工具也复用它，缺失属性保留 null。

共享读取器没有改变已有诊断的成功 / 失败处理，只减少重复实现。取消生命周期后不得访问原生句柄，已增加 disposed 防护测试。

## 最终离线验证

- `flutter test --no-pub test/pages/danmaku test/services/diagnostics_test.dart test/plugin/pl_player/video_output_size_test.dart`：51 项通过。
- 改动目录的 `flutter analyze --no-pub`：No issues found。
- `dart format`：已执行。
- `git diff --check`：通过。
- 最终“不主动退出”工具的 Windows Profile 构建：成功。**未启动该最终构建，退出稳定性未验证。**
- Windows runner 的试验性修复：已经撤回，当前与起点一致。
- 自动批量运行脚本、诊断器、原始 JSON、日志和生成的 Windows 缓存：仅保存在忽略的 `build/`。
- 当前没有本轮 PiliAurora 进程。WerSvc 未改动，第三方共享 Pub 缓存未改动。

这些检查覆盖 Dart 行为和编译正确性，不覆盖 Windows 原生插件退出。缓存对照收益、长时间内存趋势和视觉一致性仍未完成。

## 下一步与权限边界

1. 先获得本机 0xE0464645 的完整故障栈，或做未使用插件的隔离对照。不要继续随机更换退出 API。
2. 若处理 WebView 依赖，优先在实验分支使用本地补丁，不修改共享 Pub 缓存、不升级全部插件。依赖改动需另行确认。
3. 在 COM apartment 仍有效、正确线程上释放原生对象；检查多 engine 和 DispatcherQueue 异步关闭语义。
4. 验证启动 → 播放 → 销毁 → 进程正常退出，再恢复缓存预算实验。
5. 退出稳定后做 16 / 24 / 32 MiB 反转顺序对照，先保持 96 MiB 活动预算不变。
6. 最后完成长时间生命周期、DPI、多屏、4K 和不同设备测试。

未确认根因之前，不宣称已修复，不更改生产预算默认值，不通过启用 WER 或强制终止隐藏失败。

[EXIT-ISSUE]: https://github.com/DanXi-Dev/DanXi/issues/498
[WEBVIEW-H]: https://github.com/bggRGjQaUbCoE/flutter_inappwebview/blob/0bfa46dfff87f0d9e9d5e13cbd5c4a7c7310f8c9/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.h
[WEBVIEW-CPP]: https://github.com/bggRGjQaUbCoE/flutter_inappwebview/blob/0bfa46dfff87f0d9e9d5e13cbd5c4a7c7310f8c9/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp
[WEBVIEW-PLUGIN]: https://github.com/bggRGjQaUbCoE/flutter_inappwebview/blob/0bfa46dfff87f0d9e9d5e13cbd5c4a7c7310f8c9/flutter_inappwebview_windows/windows/flutter_inappwebview_windows_plugin.cpp

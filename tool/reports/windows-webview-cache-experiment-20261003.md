# Windows WebView 退出修复与 Raster Cache 对照（2026-10-03）

## 结论

1. Windows WebView 插件的进程退出 `0xE0464645` 已在单插件隔离实验中复现。提前释放静态资源的仓库内补丁通过同一红绿验证。
2. 本地页面创建、JavaScript DOM 读取、headless 容器释放及完整原生进程退出通过。空入口完整插件集及真实本地视频+音频+弹幕短烟雾也正常退出。
3. 完成 16/24/32 MiB × 预热开/关的两轮反转顺序 Windows 回放，12 个正式窗口有效，所有进程正常退出。
4. 扩大缓存减少关键路径栅格化和部分入场耗时，但帧时间 P95 没有一致改善。保持默认 16 MiB，不改变预热默认或 LRU 策略。
5. 原因计数不等于图片释放计数；新增互斥的布局/图片淘汰计数以及淘汰图片账面字节。

本报告是本机短窗口实验，不代表跨设备、跨线程多 engine、所有真实 WebView 页面或长时间 Private Bytes 增长均已验证。研究第 2 项，不扩展第 3/4 项性能研究。

## 1. WebView 退出：隔离复现

### 安全回路

`tool/windows_shutdown_probe.py` 使用标准库 Win32 调试器接口，仅调试自己创建的 64 位测试进程。根据已加载模块地址，给该进程的 `RaiseFailFastException` 与 `NtRaiseHardError` 设置断点。

先执行 `guard-selftest`：测试进程主动调用 `RaiseFailFastException`，记录为预期失败，拦截 code=0xE0464645。只有拦截自检通过才加载故障插件。故障拦截后终止自身测试进程并返回失败；**不把强制结束当作正常退出**，不修改 WER、注册表、服务或用户进程。

已保存的自检结果为 `build/webview-guard-selftest-20261003/`。固化入口 `tool/windows-runner-lifecycle.ps1 -WithWebView` 会自动执行该自检。

### 原包红灯

真实 Flutter runner+引擎只注册锁定的 Windows WebView 插件，没有 WebView 页面或 mpv。

- 插件注册成功；engine/窗口 teardown 回调测试已完成。
- 随后进入 `RaiseFailFastException`，记录 code `0xE0464645`；调试器在调用前拦截。
- 栈扫描候选含 CoreMessaging、DComp 和 `flutter_inappwebview_windows_plugin.dll`。它不是完整符号栈，不虚构具体上游函数。
- 原始证据：`build/webview-original-isolation-20261003/result.json`，`events.log`。

此前仅凭相似报告提出的 WebView 猜测，现在有本机、单插件、同一锁定版本的红灯证据。

## 2. 本地补丁与绿灯

用户明确允许实验与相关依赖副本修改。将锁定包 flutter_inappwebview_windows 0.6.0 复制到 `third_party/flutter_inappwebview_windows`，来源提交 `0bfa46dfff87f0d9e9d5e13cbd5c4a7c7310f8c9`。

- 保留原许可证、版本、Dart 源码及上游 analyzer 配置。
- 不升级 WebView2/WIL/其他包，不修改共享 Pub 缓存。
- `pubspec.yaml` 改用仓库内 path；离线 pub get 的 lock 差异仅为该包的来源。
- 上游功能补丁只改 3 个 C++ 文件：manager header、manager cpp、plugin cpp。溯源说明见本地包 `UPSTREAM.md`。

### 资源顺序

- plugin 先销毁 headless 与 browser 容器，然后销毁普通 WebView manager，最后释放 cookie/environment manager。
- manager 引用计数归零时，释放静态 Compositor → GraphicsContext → DispatcherQueueController → RoHelper，并复位 valid。
- 资源在最后一个 manager 所在线程、COM 仍初始化的阶段释放，而不留到 DLL 静态析构阶段。

未新增显式 `ShutdownQueueAsync` 或消息循环 drain。该最小补丁的绿灯证明本机故障已被消除，不证明异步队列在所有应用模式都已完全 drain。已有静态资源设计并非线程局部；计数同样不宣称提供跨线程支持。

### 验证结果

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 单 manager/engine 原始红灯回路 | 正常退出 0，无 fail-fast | `build/webview-release-isolation-20261003/` |
| 同进程顺序重建 3 次 engine/manager | 正常退出 0 | `build/webview-release-recreate-20261003/` |
| 真实 main 返回顺序，包含 WebView 注册 | 正常退出 0 | `build/webview-final-guarded-suite-20261003.log` |
| 完整生产插件集，空 Dart 入口 | READY 后 WM_CLOSE，正常退出 0 | `build/webview-full-plugins-shutdown-20261003/` |
| 本地 HTML headless WebView、DOM读取、dispose | DOM=ready，READY code=0，正常退出 0 | `build/webview-dom-shutdown-20261003/` |
| 正常无调试器的视频+音频+弹幕短烟雾 | 43.042→45.042s有效窗口；68接受/243拒绝；退出0 | `build/webview-playback-no-debugger-20261003/` |
| 矩阵预检烟雾+12个正式窗口 | 全部有效并正常退出0 | `build/cache-matrix-20261003/` |

### 未通过与无效实验

- 并发两个 engine 的诊断样例，在注册 WebView 之前就发生 Flutter 引擎访问冲突；不注册 WebView 的对照同样失败。两次分别记录于 `build/webview-release-multi-engine-20261003/`、`build/native-multi-engine-control-20261003/`。没有把它误归为依赖补丁错误；该用例未固化为通过型测试。并发多 engine 仍未验证。
- 附加自建调试器的有音频、无音频两次播放都停在40.084s，replayWindowValid=false；正常无调试器的相同音频路径恢复推进。确认“在本诊断模式下测量无效”，未确认调试器导致停滞的内部机制；退出诊断数据不用于性能结论。
- 没有更换退出 API、启用 WER、强制退出后宣称成功或删除旧失败证据。

## 3. Raster Cache 语义与新增观测

详见 `windows-raster-cache-research-20261003.md`。

- `evictionsByBytes` / `evictionsByEntries` 表示每次 trim 前的压力，可同时计数；删零图片字节的布局项也能计入字节压力。
- 新增 `evictedLayouts` / `evictedImages` 互斥且和等于 evictions。
- `evictedImageBytes` 只累计被移除缓存 handle 的图片账面字节。clone 或引擎延迟释放可能继续持有 backing，不能把它写成实际释放内存。
- clone 生命周期测试进一步验证 clone 的真实像素一致，而不是仅检查 width 字段。
- 保留现有按 get 提升的统一 LRU；拒绝布局可能驱逐图片、独立旧布局 rasterize 可能自淘汰的行为已复现，暂不将策略变化混入容量实验。

离线约28MiB容量回放：一次性unique在所有容量都需生成116张；12-key repeated在所有容量都只需12张；整批预热同序扫描在16/24出现容量悬崖，32可全命中。这是明确的人工负载，不作为生产默认扩容依据。

## 4. Windows 真实回放矩阵

### 固定条件与验收

- 本机、本地匿名fixture；AV1 1280×720，输出1280×691，DPR1.5，auto-copy实际d3d11va-copy。
- prepared，活动账面上限96MiB，条目512，起始40s，暖机3s，测量10s，每条件独立进程。
- 两轮容量与预热反转顺序，共12个正式窗口；另外2秒烟雾不并入统计。
- 不附加调试器。每轮要求媒体窗口有效、READY code=0、发送WM_CLOSE给自身PID窗口、进程退出0。失败立即停止。
- 所有正式窗口均有效；两类mpv drop采样首尾均0。FrameTiming不是GPU时间线或最终显示延迟。
- 第一轮接受数302～322、拒绝数885～905，第二轮更接近（预热开均320/887；关预热24为319/888，16/32为320/887）。全部到期源元素总数1207，但admission并不完全相同，第一轮性能归因须保留限制。
- 原始日志/JSON仅在忽略的build目录；仓库只保存无正文、媒体路径或账号的聚合数值 `windows-raster-cache-matrix-20261003.json`。

### 结果

“需求栅格”=窗口 rasterizations 增量 − prewarmed 增量，仅指普通缓存路径。图片/布局淘汰是新增互斥分类。Private 为测量末端单快照，不是增长斜率。

| 缓存MiB | 预热 | 轮次 | 需求栅格 | 图片/布局淘汰 | mean add μs | Raster P95 ms | Total P95 ms | Private MiB | 接受/拒绝 |
| ---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 16 | 开 | 0 | 152 | 882 / 235 | 34.04 | 3.284 | 5.060 | 622.20 | 319 / 888 |
| 24 | 开 | 0 | 80 | 786 / 142 | 26.27 | 3.692 | 5.789 | 626.74 | 322 / 885 |
| 32 | 开 | 0 | 30 | 734 / 72 | 16.49 | 4.022 | 6.361 | 634.98 | 302 / 905 |
| 32 | 关 | 0 | 240 | 181 / 355 | 88.11 | 2.611 | 4.688 | 568.92 | 302 / 905 |
| 24 | 关 | 0 | 244 | 217 / 483 | 81.03 | 2.583 | 4.574 | 569.93 | 318 / 889 |
| 16 | 关 | 0 | 256 | 252 / 520 | 85.31 | 2.505 | 4.494 | 568.38 | 319 / 888 |
| 32 | 关 | 1 | 240 | 176 / 355 | 80.80 | 2.572 | 4.667 | 571.97 | 320 / 887 |
| 24 | 关 | 1 | 247 | 220 / 480 | 82.00 | 2.735 | 4.693 | 571.24 | 319 / 888 |
| 16 | 关 | 1 | 257 | 253 / 519 | 83.61 | 2.822 | 4.788 | 572.77 | 320 / 887 |
| 16 | 开 | 1 | 152 | 884 / 234 | 36.23 | 3.449 | 5.387 | 621.54 | 320 / 887 |
| 24 | 开 | 1 | 71 | 777 / 146 | 23.40 | 3.469 | 5.389 | 629.80 | 320 / 887 |
| 32 | 开 | 1 | 31 | 734 / 73 | 17.11 | 3.440 | 5.498 | 644.13 | 320 / 887 |

### 如何解释

- 预热开启，16→32MiB把需求栅格从152降为30/31，平均入场从约34～36μs降为约16～17μs。收益发生在入场路径。
- 但Raster/Total P95没有一致改善：第一轮32MiB更高；第二轮Raster基本持平、Total仍略高。不能把“栅格次数下降”写成已证明整体更流畅。
- 关闭预热时，需求栅格仅从256/257降至240。高淘汰数中布局项占比很大；减少淘汰次数并不等于同等减少图片生成。
- 预热开三档Private末端约622/627～630/635～644MiB；关预热约568～573MiB。不能只归因cache容量，不能从10秒快照推论长期泄漏。
- 16MiB预热开的布局淘汰为234/235，关闭时519/520；旧ByBytes会把这些也算进去。新增分类消除了“全是图片被字节预算驱逐”的误读。
- 各条件ByEntries增量均0，本窗口压力来自字节条件，布局项仍参与统一LRU。

### 决策

维持16MiB默认，不更改海量模式、活动预算、预热默认或LRU。以后若优化预热准入/拒绝布局策略，应独立A/B，在完整相同admission和更长窗口下验证关键路径、帧分位和资源趋势，不把本轮容量改成新默认。

## 5. 验证与限制

- Dart相关整组61项通过（容量回放是一个测试，内部9种情况）；日志 `build/cache-followup-tests-20261003.log`。
- 本项目改动范围静态分析 No issues found；含新增本地WebView fixture的最终范围见 `build/webview-cache-analysis-final-20261003.log`。
- 上游Windows包Dart业务逻辑未改；4个文件中5行既有尾空白按检查要求清理（仅空行或注释）。单独analyze其副本仍有203项既有诊断（2 warning、201 info）；其中未使用变量与dead code存在于原锁定源。未扩大修改范围或新增忽略规则来追求零告警。最初未复制包级配置时有464项诊断，随后原样保留上游analysis_options得到上述结果。
- 原生runner严格告警构建、WebView隔离suite、Python编译、PowerShell语法与git diff --check通过。
- 无新依赖版本；共享 Pub 缓存保持干净。用户允许按功能提交；未推送/合并。
- 正常应用 Windows Profile 已用 `flutter build windows --profile --no-pub --target lib/main.dart` 重建成功（145.6秒），日志 `build/webview-cache-main-profile-final-20261003.log`；最终输出已恢复正常应用入口。未运行登录、真实在线页面、DPI/多屏、多设备和长时间Private增长验证。


## 按功能提交

- `986c542f2`：Windows runner 重入与 COM 生命周期。
- `9aea30e6b`：静态转滚动遵循 hideScroll。
- `170ffd7b6`：前述修复与轨道研究记录。
- `961eac677`：本地 Windows WebView 生命周期补丁及退出测试工具。
- `9a736c282`：Raster Cache 淘汰负载分类与容量/真实播放对照工具。
- 本报告、匿名矩阵聚合与缓存研究文档单独提交。没有推送或合并。

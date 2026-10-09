# Android 固定输出与解码诊断（2026-10-09）

## 固定的是默认全屏基准

- 首次启动保存默认沉浸式全屏画布的**物理像素**，采用 `FlutterView.display.size`，不是当前页面的 viewport、逻辑像素或 PiP/分屏窗口大小。
- `androidFullscreenCalibration` 位于设置 Box，参与已有设置导出/导入。导入值保持不变，不在旋转、全屏切换或启动时覆盖。
- 设置 → 播放设置 → **重新校准全屏视频基准**可显式重测；校准失败保留旧值。重新打开播放器后采用新基准，正在使用的播放器不被突然 resize。
- 每次加载媒体，视频参数可用时计算一次输出：基准按源的长/短边对齐，`scale = min(1, baselineWidth/sourceWidth, baselineHeight/sourceHeight)`。源任一边超过对应基准时，以常量为上限等比缩小；否则保留源尺寸。输出向下取整并至少保留 1 像素，保持源画面比例。
- 例：全屏基准 2400×1080，1920×1080 源保持 1920×1080；3840×2160 源输出 1920×1080；4800×2160 源输出 2400×1080；1080×1920 竖屏源保持原尺寸。基准与源比例不一致时，输出按源比例适配常量范围。
- 同一媒体加载周期内不随视频参数重复通知或 Flutter 旋转/缩放/小窗而改尺寸。切源、显式重载重新确定尺寸；Surface 重新挂载可以重提交相同值。原生 GPU 输出不是改变视频编码分辨率，也不提升源细节。
- Android 页面不再发起旧的自适应尺寸/保护帧交接。Windows 保留原路径。旧 `enableAndroidVideoOutputSize` 设置及 `ANDROID_VIDEO_OUTPUT_SIZE` define 不再控制正式 Android 输出。

## 日志通道

关于 → 性能与诊断 → **播放器与解码日志等级**；独立于通用日志和性能记录开关。

| 通道 | 单文件 / 数量 | 总保留上限 |
| --- | --- | --- |
| `runtime.jsonl` | 8 MiB × 4 | 32 MiB |
| `player.jsonl` | 16 MiB × 8 | 128 MiB |
| `performance.jsonl` | 16 MiB × 4 | 64 MiB |

- 默认播放器等级 **信息**：加载/卸载、播放/缓冲/结束、视频参数、原生错误、Surface 配置及解码器状态变化。
- **调试**：mpv debug 消息、seek 和回退判断/预算、每 2 秒完整快照。**跟踪**：mpv trace、每 250 毫秒完整快照；只在问题复现期间开启，避免长期额外采样与写盘。
- 关闭播放器日志只停止保存，仍请求原生 error 保证已有播放错误/解码恢复功能不变。本次不改变回退策略，不宣称回退根因已经解决。
- 每条记录含 UTC 时间、运行编号、全通道序号、进程单调时间；播放器记录含 `playerId` 和 `mediaGeneration`。Android 原生 Surface 记录另含 `nativeSequence`、`nativeElapsedNs`、Surface 代数、实际 buffer、设备/系统信息。
- 错误边界保存 hwdec 请求/当前值、视频解码/输出参数、VO、缓存、丢帧和 Flutter 视口/缩放矩阵等快照；同前缀 mpv 错误快照最多每秒一次，但 mpv 原始错误逐条保留。原生框架异常单独限频并给出合并计数，避免异常风暴淹没通道。
- 不逐帧记录位置/纹理消费；原生首帧及布局状态变化只在边界记录。URL 查询、Cookie、凭据等仍脱敏。
- 写入按最多 1 MiB 批次合并，队列上限提高为 32768 条且 32 MiB，单条 1 MiB。仍有有界保护；不能承诺磁盘满或无限错误风暴零丢弃。诊断页/导出清单记录丢弃原因、队列占用、轮转次数和已淘汰文件/字节。
- 最近 200 条是 UI 有界预览，不是完整记录。导出 ZIP 包包含三个通道及各自保留的轮转文件，不只导出预览。

## 复现和验收

1. 重开播放器，分别覆盖 1080p/4K/竖屏源、硬解/软解，播放与暂停时反复旋转、进入小窗与回到全屏。
2. `surface.configure.*` / `surface.buffer-configured` 应只出现在媒体加载/重挂载，不随 Flutter 布局变化出现尺寸提交；`flutter.layout.changed` 可对照原生输出是否稳定。
3. 针对解码回退，先用调试等级复现，必要时短时切跟踪；记下异常发生时间并导出，不同时更换解码配置和源。
4. 对照 `decoder.recovery.scheduled`（触发原因）、`decoder.recovery.apply`（from/to）、`decoder.apply.begin/end`（原生快照）、`decoder.state.changed`，判断是原生自行回退、应用兜底切换还是软件重载。
5. 单元/通道测试与 Android APK 构建不替代实机 GPU/MediaCodec 及像素级验收。

## 回归命令

```powershell
flutter test --no-pub test/plugin/pl_player test/services/diagnostics test/services/diagnostics_test.dart test/services/player_logging_test.dart test/services/android_video_calibration_test.dart
flutter analyze --no-pub lib test tool
dart run tool/check_dependencies.dart
# 本机 Gradle 需要项目临时目录与 IPv4 loopback；仅对该终端设置，不写入仓库配置。
$env:TEMP = "$PWD/.gradle-tmp"; $env:TMP = $env:TEMP
$env:JAVA_TOOL_OPTIONS = '-Djava.net.preferIPv4Stack=true'
flutter build apk --debug --target lib/main.dart --no-pub
```

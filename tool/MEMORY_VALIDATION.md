# Windows 内存验证

本轮修复定位到了图片解码器延迟释放、长图解码尺寸无面积限制，以及视频进度预览缓存只限数量的问题。以下数据来自组件测试，尚不能据此推断整个 Windows release 进程的峰值降幅。

## 已验证的修复

- 图片退出且缓存保活结束后释放原生 codec；退出后才完成的 codec 也会释放。静态图片首帧完成后即可释放 codec。
- 图片直接从缓存文件创建 ImmutableBuffer，省去 Dart Uint8List 副本。同 URL 不同尺寸的并发文件请求合并，完成及失败后不保留请求表项。
- 首页、动态等 NetworkImgLayer 缩略图最多解码 1,048,576 像素，约 4MiB RGBA。测试的 400×16000 长图，原逻辑解码成 300×12000（13.7MiB），现在不超过 4MiB。长图预览可能变软，打开原图仍使用完整分辨率。
- Flutter 解码图片 LRU 上限为 64MiB / 256 项。此上限不包含正在显示、仍有监听者的图片，也不等于进程内存上限。
- 视频进度预览缓存同时限制 3 项和 24MiB。单张超限时仅供当前预览显示，关闭预览后释放；过期请求不再写回缓存。
- 动图继续保留至少 100ms 的帧间隔，减少短帧动图的 CPU 开销。

回归测试使用本地生成图片和可跟踪 codec，不需要联网或登录：

```powershell
fvm flutter test --no-pub test/common/widgets/image/image_lifecycle_test.dart test/plugin/pl_player/preview_image_cache_test.dart
```

## 整个进程的复测

使用相同应用设置、窗口大小、系统缩放、账号、视频、分辨率、解码方式和播放时长比较两个 release 版本。每轮重新启动应用。

```powershell
pwsh -File tool/trace-windows.ps1 -DurationSeconds 180 -IntervalMilliseconds 250 -SkipGpuCounters
```

建议分别记录：

1. 启动后空闲 30 秒。
2. 首页连续刷新 10 次，并往下滚动、返回顶部。
3. 动态瀑布流滚动 60 秒，覆盖长图和动图，再空闲 30 秒。
4. 固定视频播放 60 秒，移动进度预览，再关闭播放页面并空闲 30 秒。

`WorkingMiB` 是采样时的工作集；`PrivateMiB` 是私有提交量。`ProcessPeakWorkingMiB` 是 Windows 记录的**本次进程启动以来**的工作集峰值，可以捕获采样间隔内的尖峰，不能单独代表本次场景的增量。需要 GPU 数据时去掉 `-SkipGpuCounters`；GPU 计数器读取较慢，实际采样间隔可能变长。

视频解码表面、mpv、Flutter 引擎、GPU 驱动分配不包含在 Dart 图片缓存预算内。真实播放场景仍需用上述采样确认，不能把 64MiB 或 24MiB 当成整个应用的内存目标。

## 解码器测试弹窗

弹窗曾混用 Flutter 原生 Material 和应用使用的 material_ui，触发
`No MaterialLocalizations found`，表现为只有遮罩、没有面板。现已统一组件库。
`test/pages/setting/decoder_test_dialog_test.dart` 验证打开关闭、样本加载超时后重试、
格式选项操作，以及关闭后忽略迟到响应。这些组件测试不代表目标显卡已通过硬解测试。

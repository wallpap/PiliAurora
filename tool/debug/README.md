> **2026-10-09 方案更新：** 正式 Android 播放器已停止视口自适应尺寸提交，改为默认全屏校准常量与源尺寸的固定输出。下文自适应/保护帧交接和 `ANDROID_VIDEO_OUTPUT_SIZE` 对照步骤是旧方案的历史诊断记录，不能再作为当前正式实现的验收。当前设置、日志通道与实机流程见 `doc/android_fixed_output_diagnostics.md`。

# Android 暂停旋转诊断入口

`paused_rotation.dart` 是独立 Flutter 入口，只加载本地文件、原生播放器和应用实际使用的 `FittedBox + SimpleVideo` / Android Surface 调整方法和正式 VideoOutputResizer 调度器。入口不初始化账号、持久化设置或线上请求，也不加载真实视频链接。完整 PLVideoPlayer 页面的播放效果还需要实机回归。

`paused_rotation_probe.py` 使用 adb 在**指定模拟器**上安装该测试 APK，依次检查暂停状态下横屏、竖屏、横屏的画面四个象限与源边缘。只接受 `emulator-*` 序列号，避免把调试包安装到真实设备。测试视频必须具有工具所检查的红、绿、蓝、黄色象限和白色边缘；不能任意传入普通视频后把失败当作旋转回归。

- 退出码 0：三阶段像素检查均通过，且保持暂停。
- 退出码 1：初始横屏画面有效，但随后旋转阶段失败。
- 退出码 2：初始画面无效或阶段不完整，**不能推断旋转 bug 是否复现**。
- 该入口用于诊断，不加入普通 CI。没有有效初始画面时，应检查系统引导/ANR、解码器或图形驱动，不继续比较截图。

## 使用现有只读 AVD

不要安装到有用户数据的真实设备，不要 wipe-data、删除 AVD 或改写共享模拟器配置。以 SDK 已安装的 AVD 为例，在隐藏的后台进程中使用 `-read-only -no-snapshot -no-window`，并给此次测试显式分配端口。结束后只关闭此次启动的序列号，不执行全局 `adb kill-server`。

1. 生成测试图：

   ```powershell
   flutter build apk --debug --target tool/debug/paused_rotation.dart --dart-define=CREATE_ROTATION_FIXTURE=true --no-pub
   ```

   在只读模拟器安装运行该包，**先确认完整四象限画面和白边实际显示**，再用 SDK 自带 `screenrecord` 记录为 H.264 MP4，并 adb pull 到 `build/rotation-smoke/fixture.mp4`。不要录制真实应用或用户数据，也不要把系统弹窗录成测试视频。

2. 构建正常诊断入口，另存 APK，避免与最终应用产物混淆：

   ```powershell
   flutter build apk --debug --target tool/debug/paused_rotation.dart --no-pub
   Copy-Item -LiteralPath build/app/outputs/flutter-apk/app-debug.apk -Destination build/rotation-smoke/probe.apk
   python tool/debug/paused_rotation_probe.py --adb E:/SDK/Android/platform-tools/adb.exe --serial emulator-5580 --apk build/rotation-smoke/probe.apk --fixture build/rotation-smoke/fixture.mp4
   ```

3. 对照构建可以加 `--dart-define=ANDROID_VIDEO_OUTPUT_SIZE=false`。仅在两组初始画面都有效时，才比较自适应尺寸与源尺寸两条路径。
4. 保存结果到忽略的 `build/rotation-smoke`，不要把视频、模拟器日志或截图提交到仓库。结束后重新构建 `--target lib/main.dart`，不要将诊断 APK 当作应用交付。

## 2026-10-07 的执行边界

没有连接的实机。使用现有 AVD 的只读实例尝试了硬件和软件 GPU 路径：硬件路径有 OpenGL INVALID_OPERATION，软件路径出现 System UI ANR。期间还发现 MJPEG 不在当前 Android 原生包支持的解码器范围内，随后改用 SDK screenrecord 的 H.264；但系统弹窗/ANR 污染了测试图，初始画面检查仍无效。

本次确认了诊断入口能构建、控制旋转并捕获像素，但未复现用户报告的局部裁切。后续根据实际调用路径发现并修正了半次尺寸提交、请求/成功缓存混淆及源参数重建与视口调整不共用队列的问题，回归测试证明这些时序不再产生两端尺寸不同步；通道时序测试无法确认实机上的像素显示。

## 实机验收（正常应用包）

1. 使用正常应用入口构建的 APK，进入关于 → 性能与诊断，开启记录性能，日志等级选 info。不要把隔离诊断入口安装到用户实机。
2. 用同一视频分别在播放中、暂停后执行全屏 → 竖屏 → 全屏，至少重复三次；记录异常发生的秒级时间。确认暂停时画面完整、没有被自动恢复播放或 seek。
3. 同时检查播放旋转是否仍黑闪、暂停后恢复播放是否正常。建议分别覆盖 1080p / 4K 和硬解 / 软解，切源时是否异常单独记录。
4. 导出诊断包；新版本有 `videoViewport.*` 状态及 `video.output` 提交事件，可区分 Flutter 缩放、源重建与原生几何不同步。
5. 如果仍异常，用同一代码构建 `ANDROID_VIDEO_OUTPUT_SIZE=false` 的正常应用对照包。只改变这一项，不同时更换解码配置或视频源，否则无法判断因果。

Android 使用 250ms 的稳定窗口；暂停期间不新增自适应提交，源参数重建仍由插件负责。调度器测试覆盖了停留 150ms 的中间几何、暂停和恢复、通道延迟、失败、切源及销毁。设备旋转过渡可能超过 250ms，这个窗口不能当作动画完成事件；若仍有闪屏，请对照实际尺寸提交的时间继续排查。

本轮正常应用 Debug 对照产物（不是独立诊断入口）：

- `build/rotation-check/PiliAurora-debug-rotation-fix.apk`：开启修正后的自适应路径。
- `build/rotation-check/PiliAurora-debug-rotation-control.apk`：同一代码，仅设置 `ANDROID_VIDEO_OUTPUT_SIZE=false`。
- `build/app/outputs/flutter-apk/app-debug.apk` 已恢复为开启修正路径的正常应用包。旧的 adaptive / source-size 文件不作为本轮结果，避免用不同代码版本比较。

这些是 Debug 验收包，不是已签名的正式 Release 发布；未安装到实机，也未上传到远程服务。


## 2026-10-09：保留自适应的帧交接

旧 adaptive/control APK 属于旧构建，不能验收本轮行为。正式入口和隔离入口已接入 `VideoOutputHandoff`：旋转布局期间先用 Flutter 缩放旧纹理；稳定后先提交内容快照，等匹配帧编号的 Flutter raster 回执，再 resize；等提交后 EGL 帧被 Flutter 消费后移除快照。`endOfFrame` 不单独放行 resize。`ANDROID_VIDEO_OUTPUT_SIZE=false` 的单变量对照仍可使用。

正常应用诊断会出现 `resizePolicy=state-machine-frame-handoff` 和 `handoffActive`。`resize.completed/accepted=true` 现在包含本次消费等待和快照移除，不再仅表示两次尺寸调用结束。无法捕获有效图片或检查帧时钟时会拒绝本次优化，不能把 `accepted=false` 误认为已执行安全交接。

暂停期间不开始新提交；已经开始的交接不自动恢复播放。若等待新帧时切源、Surface 重建或销毁，取消旧请求并解除 native 队列。验收需额外覆盖快速反向旋转、交接期间暂停后恢复、4K 和交接中切源。既有 probe 仍只检查三个暂停阶段的整帧，不检查旋转中每帧黑闪。

自动验证：

```powershell
flutter test --no-pub test/plugin/pl_player/video_output_paint_barrier_test.dart test/plugin/pl_player/video_output_handoff_test.dart test/plugin/pl_player/video_output_handoff_widget_test.dart test/plugin/pl_player/android_video_frame_handoff_test.dart test/plugin/pl_player/video_output_resizer_test.dart test/plugin/pl_player/android_video_output_test.dart test/plugin/pl_player/video_output_state_test.dart
javac -d build/rotation-stable/java third_party/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video/SurfaceFrameFence.java tool/debug/SurfaceFrameFenceProbe.java
java -cp build/rotation-stable/java com.alexmercerind.media_kit_video.SurfaceFrameFenceProbe
```

主机 Java 检查不安装应用或修改设备，只验证实际生产 fence 的判断条件。

正常应用交付产物：`build/rotation-stable/PiliAurora-debug-adaptive-handoff.apk`（自适应开启，入口 `lib/main.dart`，不是隔离 probe）。构建日志为同目录 `build-final.log`，回归日志为 `all-tests-final.log`；`paint-barrier-red.log` 保存旧 UI-frame 条件提前放行的失败用例。旧 adaptive/control 包不包含本次修正。

保护帧 raster 回执会被引擎批量上报；Release 中需检查可见停帧时长。正常应用实机验收同时观察黑闪、瞬时裁切、保护图是否过久停留，不能只看 native `resize.completed`。帧回执不是显示器 present fence，尺寸字段也不是每个 GraphicBuffer 的实测几何。

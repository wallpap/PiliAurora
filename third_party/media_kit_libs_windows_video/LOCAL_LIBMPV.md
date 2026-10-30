# Windows libmpv 历史验证记录

2026-10-13 验证过的本机临时修复包及应用播放结果如下。当前构建改用[仓库内的 mpv 固定源码](../mpv/README.md)，下述 DLL 校验值、测试与设备测量对应历史构建。

## 修复与来源

- [mpv #18603](https://github.com/mpv-player/mpv/pull/18603)：`video/out/opengl/hwdec_d3d11egl.c` 的 `uninit()` 在移除设备后调用 `av_buffer_unref(&p->hwctx.av_device_ref)`，再释放驱动自身的 D3D11 引用，解决渲染器销毁后设备仍存活的问题。
- [mpv #18604](https://github.com/mpv-player/mpv/pull/18604)：`osdep/language-win.c` 的 `apppend_langs()` 增加 `pos += wcslen(buf + pos) + 1`，正确遍历 Windows 多个首选界面语言。

源码取自 #18603 提交 `8fa4c6877abe110a1c07f696ff3792f56b81ccf4` 的副本，并加入上述语言修复；父基线为 `c3ac7f39514c7f45bc38a18e66887240539ee33c`。未修改原有验证 checkout。

构建使用便携 MSYS2 UCRT64，GCC 16.2.0、Meson 1.12.1、Ninja 1.13.2、FFmpeg 9.0.2、libass 0.17.5、libplacebo 7.360.1、ANGLE 890b5d8f。配置为 `debugoptimized`、`--werror`，开启 libmpv、cplayer、tests、egl-angle、egl-angle-lib、egl-angle-win32、d3d-hwaccel 和 d3d11，关闭 PDF/manpage 生成。

合并修复 DLL SHA-256：`cfc7af7483a509826f5cc4e4b1033a597814d6f14ab97bc4cca57301cc65e536`。

## 历史临时包

以下记录对应 `build/local-libmpv/` 中曾使用的本机修复包与配套 DLL。该路径已退出当前 CMake 构建流程，当前源码与运行库准备方式见[mpv 构建入口](../mpv/README.md)。旧文件和日志保留用于对照，新构建不依赖它们。

## 验证

合并源码使用 `--werror` 完整编译通过；上游现有 Meson 测试以 `GGML_NO_BACKTRACE=1`、`-j8` 执行，37/37 通过。构建和测试日志保留在对应的本地验证目录。

本地包以 AV1 852×480、输出 1280×720、Anime4K 关闭/效率/质量/再次关闭四阶段（各 2 秒）进行六轮创建、播放、销毁：所有阶段使用 `d3d11va`，帧缓冲非均匀；每轮释放后设备引用均为 0，当前私有内存为 428.68、433.42、427.95、434.34、431.35、437.33 MiB。记录位于 `build/local-libmpv-validation/results.jsonl`。

`fvm flutter build windows --debug --no-pub` 通过；打包的 `build/windows/x64/runner/Debug/libmpv-2.dll` 与上述 SHA-256 一致。首次接入检查发现符号链接相对路径未命中临时包，已改为从插件真实路径定位；更换导入库时遇到 MSVC 增量链接器 LNK1000，将生成的 `.ilk` 缓存改名保留后重建成功。构建日志位于 `build/local-libmpv-windows-build.log`。

对最终应用输出目录另跑一轮相同播放探针，硬解、出帧与设备引用归零检查通过；记录在 `build/local-libmpv-packaged-validation-fixed/results.jsonl`，日志在 `build/local-libmpv-packaged-probe-fixed.log`。

正式版 `fvm flutter build windows --release --no-pub` 构建通过，`build/windows/x64/runner/Release/libmpv-2.dll` 与修复包 SHA-256 一致。正式版输出目录的播放探针通过硬解、出帧和设备引用归零检查。构建日志为 `build/local-libmpv-windows-release-build.log`，探针日志为 `build/local-libmpv-release-probe.log`，结果为 `build/local-libmpv-release-validation/results.jsonl`。

长时间播放、实际音频输出、更多 GPU/驱动、应用 UI 中反复开关播放页面与 Android 行为未包含在本次验证中。

## 应用超分切换记录

2026-10-13，使用 `tool/probes/playback/windows_shader_switch.dart` 运行实际 Flutter 视频输出。本机带音轨片段验证了八次重建、硬解、出帧及暂停恢复；关闭后私有内存从质量模式约 900 MiB 回落至约 445 MiB，接近初始约 451 MiB。暂停重建存在约 0.33 秒时间线回退；实际音频输出与长时间播放尚未验证。

这些数值对应本机样本；运行条件与命令见[平台探针](../../tool/probes/README.md#windows-超分切换探针)。

# media_kit_libs_windows_video 本地版本

- 本地版本：`1.0.10+piliaurora.5`；来源包版本：`1.0.10`。
- 来源仓库：https://github.com/My-Responsitories/media-kit.git
- 来源提交：`73771ec38176be2d984a3049c28177bce23b54a0`。
- 来源子目录：`libs/windows/media_kit_libs_windows_video`。
- 许可证：LICENSE。
- 保留原因：固定官网推荐的标准上游 libmpv 预编译包、SHA-256 校验与 ANGLE 打包。

2026-11-09：`piliaurora.5` 将标准包固定到 shinchiro 20261104（mpv `0.41.0-1434-g46787be25`、FFmpeg `200a98d5b`）。20261105 包在分片独立 AAC 音轨上回退时跳过约 5 秒数据，引发播放重置及 AV1 解码失败。相同输入与操作在 20261104 包通过；PR 检查和 Windows 发布构建使用离线合成样片运行真实 libmpv 回归，后续更新须先通过此检查。

2026-11-10：直接 libavformat 最小复现确认回归来自 FFmpeg `cac8deb2f919` 的 `mov_read_trun` 样本游标比较变更（`<` → `<=`）。同一源码基线的提交前/后和单行撤销对照已通过，只撤销时间表游标调整不能修复。源码探针与重现方法见[样片说明](../../tool/probes/playback/fixtures/README.md#直接-libavformat-最小复现)；生产继续使用上述标准包，未引入实验原生补丁。

2026-11-05 曾使用标准上游 `0.42.0-1-g3138fc8ee`（shinchiro 20261105），移除本地 mpv 补丁及编译流程。应用会话等待旧媒体卸载后再重建超分输出，随后恢复点播位置和播放意图；此协议继续保留。原 `20260819` 归档及旧临时 DLL 的验证保留为[历史记录](LOCAL_LIBMPV.md)。

`piliaurora.4` 修正标准包头文件的装配层级：将上游 `include/mpv/` 的内容放入播放器约定的 `libmpv/include/`，避免全新 Release 构建找不到 `client.h`、`render.h` 和 `render_gl.h`。`tool/packaging/libmpv_layout_test.py` 使用生产 CMake 验证全新解压与旧头文件覆盖，不依赖已有应用构建缓存。

仅收录生产源码、构建配置、资源及许可说明；不复制上游示例、测试、缓存或 Git 元数据。
导入时除包版本、禁止发布声明及必要依赖声明外，不重写来源实现。
这些包不是 pub.dev 同名版本的镜像，不可仅修改根版本号宣称已升级。
更新流程见 `../README.md`，来源登记见 `../dependencies.json`。

原生运行库的版本、来源和许可材料由本包管理。零散通知已按原文字节去重合并；下载校验入口为 `tool/verify_libmpv.py`。

## Windows libmpv 标准上游包

Windows x64 使用 shinchiro 提供、mpv 官网列出的预编译包，固定为 `0.41.0-1434-g46787be25`（20261104 Git 构建，与 0.41.0 正式标签不同）。项目不维护 mpv 本地补丁、源码归档和编译流程。下载地址、SHA-256、源码及构建配方见 [libmpv.json](windows/libmpv.json)。

mpv 自家的 CI 包主要用于测试，官网说明它可能缺少部分功能。本机验证 0.42.0 CI 包时，未能启用 D3D11 AV1 硬解，因此使用上述 shinchiro 第三方构建。

### 获取与校验

普通 Flutter Windows 构建由 CMake 自动下载并按 SHA-256 校验到 `build/windows/x64/`，无需 MSYS2。每次配置都重新提取已校验归档中的 DLL、导入库和头文件，覆盖解压缓存。ANGLE 也在配置阶段同步解压，编译开始前即可使用其头文件和导入库。

CI 可独立运行：

```powershell
python tool/verify_libmpv.py --backward-seek
```

该命令先校验合并通知及各原文段落，再下载并校验原始归档，缓存到 `build/upstream-mpv/`，随后使用 PATH 中的 CMake 解压并运行三轮原生回退回归。[发布工作流](../../.github/workflows/build.yml)的 Windows 任务执行同一校验。更新时修改 `windows/libmpv.json` 的版本、来源和摘要，同步依赖包修订，执行依赖验收、Windows 构建及真实播放探针。

### 输出重建

上游已包含 D3D11/EGL 引用释放和首选语言遍历修复。超分切换通过应用会话卸载旧媒体，在下次 open 前重建 render context 与 ANGLE，随后恢复位置和播放意图，避免活跃解码链的补偿 seek 时序问题。这会短暂中断播放，网络媒体会重新请求。

### 许可与来源

ANGLE 使用插件原有的固定 v1.0.1 包，运行时包含其 libc++ 依赖。mpv、FFmpeg、ANGLE 等组件的许可、版权和专利通知集中在 [THIRD_PARTY_NOTICES.txt](windows/THIRD_PARTY_NOTICES.txt)，其中包含 FFmpeg GPLv3 正文。完全相同的原文共用一个章节，各组件的来源、原文件标签及原文哈希见 [来源清单](windows/NOTICE_SOURCES.json)。这两份文件与版本记录一起安装到应用的 `mpv-licenses/`。

部分静态依赖的精确二进制修订未由上游记录，这些通知的参考版本不代表二进制使用的源码版本。完整对应源码和构建材料仍需向构建方获取，发布者应按各组件许可提供对应源码。

### 验证

2026-11-09，20261104 包的离线分片 AV1/AAC 回退连续三轮通过；20261105 包在同一输入落点多出约 5 秒，并出现时间戳重置与解码错误。使用故障原媒体的本地副本，从 3066 秒加载，生产 Session 按日志原始间隔回放 42 次 seek，落点及同步检查通过，seek 阶段无原生错误或音频时间戳重置。随后超分开启、关闭均保持 D3D11 硬解、时间线推进和有效纹理。输出重建仍各记录一条 `dxva2-egl: Failed to create EGL surface` 探测日志，未阻断播放；不将它计入 seek 解码错误。Windows Release 正常入口、依赖验收和全新 CMake 头文件装配测试通过。探针使用空音频输出，真实扬声器和其他 GPU/驱动未验证。

以下为旧包的历史验收，不代表其分片回退通过：

2026-11-05，本机长 GOP AV1 对照中，原位 VO 重建仍出现解码错误。使用标准 `0.42.0-1-g3138fc8ee` 的生产 Session 重载路径通过 8 个阶段、6 次实际重载：D3D11 硬解保持启用，Flutter 纹理有效，暂停位置和恢复播放正常，音频时间线按预期推进；关闭超分后私有内存回到基线附近。

相关会话、shader、原生加载就绪和关闭测试共 90 项通过。修改的 Dart 文件静态分析无问题，Windows Debug 构建、空解压缓存的 CMake 配置及依赖维护验收通过。探针使用空音频输出，真实扬声器、长期播放和其他 GPU/驱动仍需设备验收；本轮未验证 Android。历史定制库结果见 [LOCAL_LIBMPV.md](LOCAL_LIBMPV.md)。

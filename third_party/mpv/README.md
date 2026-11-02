# Windows libmpv 构建

此目录提供 Windows x64 应用使用的 libmpv 源码与构建入口。源码固定到 mpv 提交 `8fa4c6877abe110a1c07f696ff3792f56b81ccf4`，包含 #18603 的 D3D11 设备引用释放修复，并加入 #18604 的首选语言遍历修复。来源与源码归档 SHA-256 见 [source.json](source.json)。

`source.tar.gz` 保存带修复的源码、生成脚本和单元测试，剔除本机编译目录、上游 CI 和开发缓存。提取后应用两个本地补丁：`windows-test-names.patch` 调整 Windows 测试程序名；`vo-reinit-seek.patch` 在输出切换重建视频链后立即执行补偿 seek，避免新解码器在 seek 前消费缓存中的非关键包，引发 AV1 参考帧错误和硬解回退。补丁与其余构建材料共同计入 `BUILD_INPUTS`，源码重提取会验证补丁匹配，已应用时保持原样。

归档中的代码保留版权；许可见 [Copyright](Copyright)、[LICENSE.GPL](LICENSE.GPL) 和 [LICENSE.LGPL](LICENSE.LGPL)。预编译交付包集中保存在 `prebuilt/`，工具链与编译缓存保存在 `build/`。

## 直接使用预编译包

`prebuilt/windows-x64.zip` 包含 libmpv、ANGLE、必要 DLL、导入库、头文件和许可记录；`prebuilt/SHA256SUMS` 固定归档摘要。普通开发者克隆仓库后直接运行 Flutter 构建，无需安装 MSYS2。CMake 校验归档、构建输入和每个交付文件，并解压到按归档哈希隔离的构建目录。

可用 Python 3.12 或更新版本单独校验：

```powershell
python third_party/mpv/package-runtime.py verify third_party/mpv
```

## 重新构建原生库

安装 [MSYS2](https://www.msys2.org/)，在 UCRT64 终端中进入仓库根目录，执行：

```bash
pacman -S --needed --noconfirm $(cat third_party/mpv/packages.txt)
bash third_party/mpv/build.sh
```

依赖列表供本地重建和独立原生库工作流使用。MSYS2 使用滚动更新的包仓库；mpv 源码固定，依赖二进制版本由安装时的仓库决定。构建记录实际包版本，不保证不同日期产生逐字相同的 DLL。Meson 会检查 FFmpeg、libplacebo 等依赖的最低版本。

构建使用 GCC、Meson、Ninja 和 `debugoptimized` 优化配置，开启 libmpv、D3D11VA、ANGLE、WASAPI、libcurl 网络播放、字幕、色彩管理和高质量缩放。关闭命令行播放器、Lua 与未显式选择的可选后端；Anime4K shader 通过 libmpv 属性配置，不需要 Lua。上游全部已配置单元测试在打包前运行；测试程序使用单后缀名称，改名补丁见 `windows-test-names.patch`，测试输入和断言保持原样。测试在隔离环境中运行，避免 Meson 把宿主凭据写入日志。并行度默认 4，可用 `MPV_JOBS=8 bash third_party/mpv/build.sh` 调整。

输出位于 `build/mpv/`：

| 路径 | 内容 |
| --- | --- |
| `source/` | 校验后解压的源码 |
| `compile/` | Meson 编译和测试产物 |
| `packages.txt` | 实际 MSYS2 包版本 |
| `runtime/` | libmpv、导入库、头文件、ANGLE 及其 DLL 依赖闭包 |

构建通过后自动更新 `prebuilt/windows-x64.zip` 和归档摘要。`runtime/SHA256SUMS` 校验所有交付文件，`BUILD_INPUTS` 记录源码和构建脚本摘要。DLL 通过导入表递归收集；Windows 系统 DLL 留给操作系统提供。动态按需加载的插件不在导入表内，本构建关闭 mpv 的未选后端，FFmpeg 内的非播放扩展仍需针对实际使用另行验证。

运行时携带 mpv 许可、依赖包提供的许可文本、包版本、上游地址与 DLL 归属；Flutter 打包将这些文件安装到 `mpv-licenses/`。MSYS2 包的对应源码与打包配方入口为 [MSYS2 MINGW-packages](https://github.com/msys2/MINGW-packages)。发布者需按各组件许可提供对应版本源码。

完成后回到 PowerShell，按[构建与测试](../../doc/development/build-and-test.md)构建 Flutter 应用。CMake 读取预编译归档，检查构建输入与文件摘要；构建材料变化后需更新归档。源码归档变更时需使用新的 `build/mpv/` 编译目录，已有目录可改名保留。

## GitHub CI

[Windows 应用工作流](../../.github/workflows/win_x64.yml)校验并使用仓库中的预编译包，再构建 Flutter Release 与安装程序。[原生库重建工作流](../../.github/workflows/mpv.yml)通过 [MSYS2 官方 CI 集成](https://www.msys2.org/docs/ci/)安装 UCRT64 依赖，运行同一构建脚本和 mpv 测试，上传 `prebuilt/` 作为工作流产物。维护者下载产物、核对来源与播放结果后，再更新仓库中的归档和摘要。两条流程都不依赖本机私人目录，也不自动发布 Release。

## 来源与历史验证

源码归档来自此前验证的 `mpv-local` 源码副本，没有导入其编译产物。原临时 DLL 的设备引用、播放与超分切换测量保留在[历史验证记录](../media_kit_libs_windows_video/LOCAL_LIBMPV.md)，这些结果对应当时的构建，不能替代新构建的 GPU 和音频验收。

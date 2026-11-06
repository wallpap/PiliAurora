# Windows cnativeapi 预编译包

源码位于 `../cnativeapi/`，内含 nativeapi。Windows x64 默认从 `prebuilt/windows-x64.zip` 读取 cnativeapi.dll；内部 nativeapi 静态链接，无需单独分发 .lib。DLL 使用 Release 配置，可通过 C ABI 供应用各模式的 Dart FFI 调用，避免依赖 Flutter C++ 包装层。

独立构建使用静态 MSVC 运行库（/MT），避免预编译 DLL 为应用增加较新动态运行库的要求。C ABI 的句柄和库分配内存仍通过对应释放函数归还给库。

构建入口：`pwsh -NoProfile -File third_party/nativeapi/build.ps1`，需要 Visual Studio C++ 工作负载、CMake 和 Python。CMake 不在 PATH 时用 `-CMake` 指定其路径。源码和脚本的摘要记录在 BUILD_INPUTS 中；修改后需重新构建，编译缓存在 `build/nativeapi/`。

校验入口：`python third_party/nativeapi/package.py verify`。CMake 在应用构建时核对源码、脚本、归档与交付文件摘要。许可随应用安装到 `nativeapi-licenses/`。

预编译包使用本目录的 `build.ps1` 在本地重建，普通 Windows 发布构建只校验并使用仓库中的产物。WinUI3 和非 x64 架构保留源码路径。实际窗口、托盘与系统交互需要目标设备验证。

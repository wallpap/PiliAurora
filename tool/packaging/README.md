# Windows 打包工具

从仓库根目录运行。应用构建使用 [`tool/build.ps1`](../build.ps1)，安装器与附件流程见[构建与测试](../../doc/development/build-and-test.md#发布构建与附件)。

| 脚本 | 用途 |
| --- | --- |
| `prepare_windows_package.py` | 装配并校验预编译引擎，生成运行文件摘要清单 |
| `libmpv_layout_test.py` | 用临时归档和生产 CMake 检查 mpv 头文件布局及缓存刷新 |
| `windows_package_test.py` | 检查清单、覆盖安装、旧文件清理及运行进程关闭 |

## 打包前置

```powershell
uv run --locked python tool/packaging/prepare_windows_package.py --runtime build/windows/x64/runner/Release
```

这是 fastforge 的打包前置入口。默认 Windows 构建自动生成 Release 运行目录和 `build/windows-engine-config.json`，随后即可执行本命令。脚本修改指定运行目录，安装已验证的引擎后生成 `piliaurora-runtime.sha256`；清单要求存在 `PiliAurora.exe`，拒绝符号链接、目录联接及无法表示的文件名。便携包和安装包使用同一份清单。

## 回归

```powershell
uv run --locked python tool/run_python_tests.py --suite packaging
```

清单与 mpv 布局用例使用独占临时目录。Windows 安装回归需要 Inno Setup 6，进程关闭用例还需要 .NET Framework C# 编译器；缺少条件时明确跳过。安装器夹具关闭系统集成，仅操作临时安装目录，核对用户文件和其他目录的同名程序保持完整。

原生 libmpv 下载、许可和分片音轨回归由 [`verify_libmpv.py`](../verify_libmpv.py) 维护，来源见[第三方登记](../../third_party/media_kit_libs_windows_video/UPSTREAM.md)。

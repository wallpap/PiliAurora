# Flutter Release 预编译引擎

本地 `tool/build.ps1` 默认 Release 与发布 CI 均使用 Git 跟踪的 `prebuilt/` 压缩包，校验后装配应用，无需编译引擎或指定库路径。普通命令和输出见[构建与测试](../../doc/development/build-and-test.md#构建)，采用的修复和策略见[默认构建与策略](../../doc/development/build-defaults.md)。Debug 使用 SDK 自带引擎；Profile 维护需要同模式的原生构建产物。

| 目录 | 平台 | 呈现配置 |
| --- | --- | --- |
| `android-arm` | Android armeabi-v7a | `androidFramePlan` |
| `android-arm64` | Android arm64-v8a | `androidFramePlan` |
| `android-x64` | Android x86_64 | `androidFramePlan` |
| `windows-x64` | Windows x64 | `windowsDwmPaced` |

框架固定到 Flutter 3.47.5（`6a19cca56475dbfba1478ee68d7bd0c2ef891da1`），引擎固定到 `af7e796e161ae0bb1ff0758c71a7105418bd9ded`，来源为 [Flutter](https://github.com/flutter/flutter)。平台补丁、编译入口与原生回归见 [Android](../../tool/engine/frame_plan/README.md) 和 [Windows](../../tool/engine/windows_frame_pacing/README.md)。

每份压缩包旁的 `engine-identity.json` 登记运行模式、架构、源码、补丁与二进制摘要及原生回归状态。解压时重新计算当前仓库补丁和二进制摘要，核对 ELF/PE 格式、架构及 Release 模式。原生回归未通过的产物无法打包或装配。

## 更新产物

完成对应平台、架构的 Release 编译与原生回归后，在仓库根目录执行：

```powershell
python third_party/flutter_engine/package.py pack --target android-arm64 --library <lib.stripped/libflutter.so>
python third_party/flutter_engine/package.py verify --target android-arm64
python third_party/flutter_engine/package.py unpack --target android-arm64 --output build/prebuilt-engine/android-arm64
```

其他目标使用表中的目录名。压缩使用固定时间戳；二进制与身份文件一同提交。补丁或固定引擎版本更新后，重建受影响的产物并重新运行原生回归。

Windows 工作流在 Dart 编译时绑定引擎身份，并在安装程序打包前装配同一 DLL；便携包使用同一运行目录。Android 按 ABI 编译 AOT，替换对应引擎、写入身份文件并使用正式签名重新签署，随后校验签名、ABI、AOT 库和包内引擎摘要。

## 许可证

Flutter 使用 BSD 3-Clause 许可，见 [LICENSE](LICENSE)。[NOTICE.engine.txt](NOTICE.engine.txt) 保留固定引擎源码附带的组件许可，[NOTICE.windows.md](NOTICE.windows.md) 保留同版本 Windows 引擎组件声明。定制补丁未引入额外第三方组件。Android 应用由 Flutter 构建流程收集许可证，Windows 运行目录另附引擎许可文件。

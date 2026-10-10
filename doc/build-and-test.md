# 构建与测试

## 环境

- Flutter 版本由仓库根目录的 `.fvmrc` 固定，使用 FVM 安装和调用。
- Windows 构建需要安装 Visual Studio，并启用“使用 C++ 的桌面开发”工作负载。
- Android 构建需要 Android SDK 和 JDK 25。Android Studio 的 Gradle JDK 与 `JAVA_HOME` 均应指向 JDK 25。
- Windows 开发建议使用 PowerShell 7。

## 安装依赖

```powershell
fvm install
fvm flutter pub get
```

## 构建

仓库脚本会准备依赖、应用项目所需的 Flutter 补丁，并调用对应平台的 Flutter 构建：

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

将 `-Mode debug` 改为 `-Mode release` 可构建发布版本。脚本参数和依赖来源检查见 [`tool/README.md`](../tool/README.md)。

## 静态检查与测试

```powershell
fvm flutter analyze
fvm flutter test
```

定位到单一功能时，可向 `fvm flutter test` 传入相关测试文件或目录。测试按业务领域分布在 `test/` 下。

| 改动范围 | 建议检查 |
| --- | --- |
| 页面与控件 | 对应 `test/pages/`，再运行静态分析 |
| HTTP 与模型 | 对应 `test/http/` 和模型测试 |
| 服务、下载或直播 | 对应 `test/services/` |
| 播放器 | 对应 `test/plugin/`；按目标平台补充实机验证 |
| Android 或 JNI | Android 构建及相关测试 |
| Windows 窗口或 WebView | Windows 构建及对应平台测试 |

测试和构建结果只覆盖实际执行的环境。GPU、MediaCodec、驱动、真实 WebView 和音频输出仍需在目标设备上确认。

## 生成 Android JNI bindings

```powershell
fvm dart run tool/jnigen.dart
```

protobuf 和 JNI 产物应由对应的源定义及生成流程更新。生成后检查代码差异，并运行相关测试。

## 故障定位

- FVM 不可用时，检查 `fvm`、`dart` 是否在 PATH，以及 Flutter 版本是否与 `.fvmrc` 一致。
- 依赖获取失败时，检查网络、代理、缓存和 `pubspec.lock`。
- Android 构建失败时，检查 JDK 25、`JAVA_HOME`、Android SDK 和构建脚本输出。
- Windows 播放异常时，分别检查播放器初始化、硬件解码、渲染窗口和弹幕路径。

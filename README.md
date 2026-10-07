# PiliAurora

PiliAurora 是面向 Android 和 Windows 的 Flutter Bilibili 第三方客户端，基于 [PiliPlus 2.1.5](https://github.com/bggRGjQaUbCoE/PiliPlus/tree/2.1.5) 继续开发。维护工作主要围绕 Windows 播放、弹幕渲染、硬件解码兼容性，以及性能和稳定性展开。

> 本项目与 Bilibili 官方没有隶属关系。它是独立维护的第三方客户端，使用时请遵守 Bilibili 的服务条款及适用法律。

[源码](https://github.com/wallpap/PiliAurora) · [发布版本](https://github.com/wallpap/PiliAurora/releases) · [问题反馈](https://github.com/wallpap/PiliAurora/issues) · [许可证](LICENSE)

## 与源项目的功能对比

以下对比以 PiliPlus `2.1.5` 为基线，不代表上游后续版本的功能或表现。

### 保留的主要功能

从 PiliPlus 保留的主要功能：

- 视频与番剧：视频详情、分 P、画质和音质选择、倍速播放、字幕、章节、硬件解码、音频播放和番剧播放。
- 弹幕与直播：视频弹幕、弹幕设置与屏蔽、直播分区、直播间、直播聊天和直播弹幕。
- 动态与评论：动态浏览、发布、转发、投票、话题、评论、楼中楼、点赞、回复和富文本内容展示。
- 内容管理：收藏夹、收藏夹排序、稍后再看、观看记录、离线缓存和离线播放。
- 账号与社交：登录、设备管理、多账号、关注和分组、粉丝、黑名单、私信及消息中心。
- 搜索与个人空间：视频、番剧、用户、动态、专栏和直播搜索，以及用户主页、投稿、收藏、动态和相关数据。
- 扩展功能：DLNA 投屏、WebDAV 设置备份、主题和播放参数设置、Bilibili Web 页面、SponsorBlock 等。

### PiliAurora 的主要变化

| 方向 | PiliPlus 2.1.5 基线 | PiliAurora 当前实现 |
| --- | --- | --- |
| 平台范围 | Android、iOS/iPad、Windows、Linux 等 | **仅维护 Android 和 Windows** |
| Windows 播放 | 通用播放器和弹幕渲染 | 针对 Windows 增加硬件解码兼容性测试、解码器选择与回退、AV1 解码回退、输出尺寸与帧节奏优化 |
| Windows 弹幕 | 通用弹幕渲染路径 | 增加弹幕预处理、缓存、轨迹计算、缓冲预读和更受控的渲染路径，用于降低高密度弹幕下的卡顿与内存压力 |
| Android 播放 | 基础硬件解码支持 | 增加 MediaCodec 输出异常恢复，并在硬件解码失败时执行完整的回退链路 |
| 直播与网络 | 常规请求、直播包和聊天处理 | 对直播包解码、聊天历史、压缩响应解码、下载写入回压和 UI 阻塞进行限界或后台化处理 |
| 诊断与排障 | 以常规日志和设置为主 | 增加播放器、下载、网络、直播及启动过程的结构化诊断记录，并提供解码器测试和性能观测工具 |

### 差异的实际影响

- 如果你需要 **iOS、iPad、macOS 或 Linux**，请使用仍维护这些平台的上游项目；PiliAurora 不再以这些平台为目标。
- 如果你主要在 **Windows** 上观看视频或直播，PiliAurora 更关注硬件解码选择、密集弹幕和长时间运行的稳定性。
- 播放器、渲染器和诊断基础设施的改动，未必会增加页面或 Bilibili 功能。
- PiliAurora 使用独立的应用标识和数据目录，可以与 PiliPlus 并存。两个应用的登录状态、设置、缓存和离线文件不会自动共享。

## 支持平台

- Android
- Windows x64

## 下载

前往 [Releases](https://github.com/wallpap/PiliAurora/releases) 获取安装包。发布页没有适合你设备的构建时，可以从源码构建。

版本号和构建号可在 `pubspec.yaml`、`pili_release.json` 及对应发布说明中查看。请从本仓库或 Releases 页面下载应用。

## 依赖维护

普通依赖固定到发布版的精确版本，解析结果保存在 `pubspec.lock` 中。需要定制的依赖随仓库源码维护，不跟踪远端 Git 分支。包的来源、保留原因和更新步骤见 [third_party/README.md](third_party/README.md)；解析后运行 `dart run tool/check_dependencies.dart`，核对版本、许可证和来源。

## 从源码构建

### 环境要求

- Windows 开发环境建议使用 PowerShell 7、Git 和 FVM。
- Flutter 版本由 [.fvmrc](.fvmrc) 固定；当前项目要求 Flutter `3.47.5`，Dart `>=3.13.0`。
- 构建 Android：准备 Android SDK 和 JDK 25，并将 `JAVA_HOME` 指向 JDK 25；Android Studio 的 Gradle JDK 也应使用同一版本。
- 构建 Windows：安装 Visual Studio，并启用“使用 C++ 的桌面开发”工作负载。

Android 构建使用 Gradle 9.6.0、AGP 9.2.1 和 Kotlin 2.4.20，并通过 `android/gradle/gradle-daemon-jvm.properties` 固定 Gradle 运行时为 JDK 25；应用与所有 Android 子模块（含 Flutter 插件源码）的 Java/Kotlin 编译目标及 Java 工具链统一为 25；Flutter SDK 内部构建逻辑和第三方预编译 JAR 保持其原始字节码版本。

### 构建命令

```powershell
git clone https://github.com/wallpap/PiliAurora.git
cd PiliAurora
fvm install

# Windows 调试构建
pwsh -File tool/build.ps1 -Platform windows -Mode debug

# Android 调试构建
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

发布构建：

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode release
pwsh -File tool/build.ps1 -Platform android -Mode release
```

构建脚本会准备依赖、应用项目所需的 Flutter 补丁，并执行对应平台的构建。更多说明见 [工具说明](tool/README.md)。

重新生成 Android JNI bindings：

```powershell
fvm dart run tool/jnigen.dart
```

## 开发与验证

项目使用 Flutter/Dart 的静态检查和 Flutter 测试。与播放器、弹幕、直播、下载、诊断和账号数据相关的回归测试位于 [`test/`](test/) 目录。

常用命令：

```powershell
fvm flutter analyze
fvm flutter test
```

播放器硬件解码测试会受到显卡、驱动、系统解码器和媒体文件的影响。

## 问题反馈

请通过 [Issues](https://github.com/wallpap/PiliAurora/issues) 反馈问题或提出建议。请附上以下信息：

- 操作系统、设备/显卡和应用版本；
- 复现步骤、媒体类型和是否使用硬件解码；
- 相关页面截图或脱敏后的日志；
- 若为播放问题，说明视频编码、清晰度、弹幕密度和是否可以稳定复现。

请勿在 issue、日志或截图中提交 Cookie、Token、二维码登录信息或其他敏感数据。

## 致谢与来源

PiliAurora 基于 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 开发。PiliPlus 的历史来源包括 [PiliPalaX](https://github.com/orz12/PiliPalaX) 和 [PiliPala](https://github.com/guozhigq/pilipala)。原有代码的版权与贡献归属各自作者及贡献者。

感谢上游作者、[My-Responsitories](https://github.com/My-Responsitories) 及其他贡献者的工作。项目还使用或参考了：

- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [media-kit](https://github.com/media-kit/media-kit)
- [flutter_meedu_videoplayer](https://github.com/zezo357/flutter_meedu_videoplayer)
- [Dio](https://pub.dev/packages/dio)
- 其他见 [`pubspec.yaml`](pubspec.yaml)

## 许可证

本项目采用 **GNU General Public License v3.0**，完整条款见 [LICENSE](LICENSE)。修改和分发时请遵守 GPL v3 的版权、许可、修改标注、源代码提供等要求；第三方组件仍须遵守其各自的许可证。

软件按许可证原文提供，不附带任何担保。具体权利义务以 [LICENSE](LICENSE) 及相关第三方许可证文本为准。

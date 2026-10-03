# PiliAurora

使用 Flutter 开发的 Bilibili 第三方客户端，支持 Android 和 Windows。

浏览视频与番剧、观看直播、管理收藏和离线缓存，也支持动态、评论和站内消息。

基于 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 的2.1.5版本进一步开发,做了激进的修改,对部分功能进行了优化,理论上资源使用会更少,主要为自用,欢迎尝试使用.

[源码](https://github.com/wallpap/PiliAurora) · [发布版本](https://github.com/wallpap/PiliAurora/releases) · [问题反馈](https://github.com/wallpap/PiliAurora/issues) · [许可证](LICENSE)

## 功能

- 视频与番剧：画质和音质选择、倍速播放、字幕、硬件解码和音频播放。
- 弹幕与直播：视频弹幕、直播间、直播聊天和弹幕显示设置。
- 动态与评论：浏览和发布动态、评论回复、点赞和投票。
- 内容管理：收藏夹、稍后再看、观看记录和离线缓存。
- 账号与消息：多账号登录、关注管理和站内私信。
- 搜索与设置：视频、番剧和用户搜索，主题切换、播放参数预设和 WebDAV 设置备份。

部分功能取决于 Bilibili 接口、账号权限和设备能力。

## 支持平台

- Android
- Windows

## 下载

前往 [发布页面](https://github.com/wallpap/PiliAurora/releases) 查看可用安装包，也可以按下文从源码构建。

尚未发布安装包时，请从源码构建。PiliAurora 使用独立的安装标识，可与 PiliPlus 并存；账号、设置和离线文件保存在各自的数据目录。

## 开发与构建

### 构建环境

- PowerShell 7、Git 和 FVM。
- Flutter `3.47.5`，版本由 [.fvmrc](.fvmrc) 固定；Dart 版本须满足 [pubspec.yaml](pubspec.yaml) 中的 `>=3.13.0`。
- 构建 Android：安装 Android SDK 及其所需的 Java 环境。
- 构建 Windows：安装 Visual Studio，并启用“使用 C++ 的桌面开发”工作负载。

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

发布构建将 `-Mode debug` 改为 `-Mode release`。脚本会获取依赖、应用项目所需的 Flutter 补丁，再执行构建。

构建流程见 [工具说明](tool/README.md)。

## 问题反馈

通过 [Issues](https://github.com/wallpap/PiliAurora/issues) 反馈问题或提出建议。报告问题时，请提供系统和应用版本、复现步骤，必要时附截图或日志。

## 致谢与来源

PiliAurora 基于 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 开发，并由本仓库独立维护。PiliPlus 的历史来源包括 [PiliPalaX](https://github.com/orz12/PiliPalaX) 和 [PiliPala](https://github.com/guozhigq/pilipala)。原有代码版权与贡献归属保留给各作者及贡献者。

感谢上游作者、[My-Responsitories](https://github.com/My-Responsitories) 及其他贡献者的工作。

项目还使用或参考了 [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)、[media-kit](https://github.com/media-kit/media-kit)、[flutter_meedu_videoplayer](https://github.com/zezo357/flutter_meedu_videoplayer)、[Dio](https://pub.dev/packages/dio) 等项目。依赖清单见 [pubspec.yaml](pubspec.yaml)，具体版本见 [pubspec.lock](pubspec.lock)。

## 许可证

本项目采用 **GNU GPL v3**，完整条款见 [LICENSE](LICENSE)。具体文件的独立许可和许可证版本选项以各自声明为准。

修改和分发时须保留适用的版权、许可和无担保声明，标注修改及日期；分发二进制时须按 GPL 要求提供对应源码。第三方组件须同时遵守各自的许可条件。

本项目与 Bilibili 官方无隶属关系。使用相关服务和内容时，请遵守其服务条款及适用法律。软件按许可证原文提供，不附带担保。

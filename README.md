# PiliAurora

PiliAurora 是基于 [PiliPlus 2.1.5](https://github.com/bggRGjQaUbCoE/PiliPlus/tree/2.1.5) 维护的 Bilibili 第三方客户端，支持 Android 和 Windows x64。项目由社区独立维护，与 Bilibili 官方无隶属关系。使用时请遵守 Bilibili 服务条款及适用法律。

[源码](https://github.com/wallpap/PiliAurora) · [下载](https://github.com/wallpap/PiliAurora/releases) · [问题反馈](https://github.com/wallpap/PiliAurora/issues) · [许可证](LICENSE)

## 功能

应用提供视频、番剧、直播、弹幕、动态、评论、搜索、账号管理、收藏、历史、离线缓存、DLNA、WebDAV 设置备份和 SponsorBlock 等功能。

项目在 PiliPlus 的基础上维护 Windows 播放器与弹幕、硬件解码回退和 Android 播放恢复。PiliAurora 使用独立的应用标识和数据目录，可以与 PiliPlus 并存；账号状态、设置、缓存和离线文件不会在两个应用间自动共享。

## 下载

从 [GitHub Releases](https://github.com/wallpap/PiliAurora/releases) 下载 Android APK，或 Windows x64 便携包和安装程序。各版本的变化见对应发布说明。

## 文档

- [文档索引](doc/README.md)：项目架构、功能入口、构建和维护资料
- [功能领域地图](doc/features.md)：按用户功能查找代码
- [构建与测试](doc/build-and-test.md)：开发环境、构建命令和验证范围
- [架构说明](doc/architecture.md)：应用分层、目录和关键调用关系
- [维护与排障](doc/maintenance.md)：代码维护、诊断入口和问题报告
- [版本说明](https://github.com/wallpap/PiliAurora/releases)：已发布版本及下载附件

## 从源码构建

项目使用 [.fvmrc](.fvmrc) 固定 Flutter 版本。Android 构建需要 Android SDK 和 JDK 25；Windows 构建需要安装启用了“使用 C++ 的桌面开发”工作负载的 Visual Studio。完整环境说明见[构建与测试](doc/build-and-test.md)。

```powershell
git clone https://github.com/wallpap/PiliAurora.git
cd PiliAurora
fvm install
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

## 问题反馈

请在 [GitHub Issues](https://github.com/wallpap/PiliAurora/issues) 提交问题，附上系统、设备、应用版本、复现步骤和相关页面。播放问题还请说明视频编码、清晰度、弹幕设置和硬件解码状态。分享日志前，请移除 Cookie、Token、二维码登录信息和其他账号数据。

## 致谢

PiliAurora 基于 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 开发。PiliPlus 的历史来源包括 [PiliPalaX](https://github.com/orz12/PiliPalaX) 和 [PiliPala](https://github.com/guozhigq/pilipala)。感谢原项目作者、[My-Responsitories](https://github.com/My-Responsitories) 和其他贡献者。组件来源见 [`pubspec.yaml`](pubspec.yaml) 与 [`third_party/README.md`](third_party/README.md)。

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE)。第三方组件遵循各自的许可证。

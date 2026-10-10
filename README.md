# PiliAurora

PiliAurora 是基于 [PiliPlus 2.1.5](https://github.com/bggRGjQaUbCoE/PiliPlus/tree/2.1.5) 继续开发的 Bilibili 第三方客户端，当前维护 Android 和 Windows x64 版本。项目重点维护 Windows以及 Android 。

本项目由社区独立维护，与 Bilibili 官方无隶属关系。使用时请遵守 Bilibili 服务条款及适用法律。

[源码](https://github.com/wallpap/PiliAurora) · [下载](https://github.com/wallpap/PiliAurora/releases) · [问题反馈](https://github.com/wallpap/PiliAurora/issues) · [许可证](LICENSE)

## 功能

项目保留 PiliPlus 的主要功能，包括视频、番剧、直播、弹幕、动态、评论、搜索、账号管理、收藏、历史、离线缓存、DLNA、WebDAV 设置备份和 SponsorBlock。

相较于 PiliPlus 2.1.5，PiliAurora 增加了 Windows 播放器和弹幕路径的优化、硬件解码回退，以及 Android 播放异常恢复。应用使用独立标识和数据目录，可与 PiliPlus 并存；两个应用不会自动共享账号状态、设置、缓存或离线文件。

## 平台与下载

- Android
- Windows x64

从 [Releases](https://github.com/wallpap/PiliAurora/releases) 下载适合设备的安装包。版本号和构建号记录在 `pubspec.yaml` 及对应发布说明中。

## 文档

- [文档索引](doc/README.md)：项目结构、功能领域、构建和维护说明
- [功能领域地图](doc/features.md)：按应用功能查找代码入口
- [构建与测试](doc/build-and-test.md)：准备开发环境并构建、验证项目
- [架构总览](doc/architecture.md)：应用分层与主要目录
- [维护与排障](doc/maintenance.md)：常用代码链路和维护约定
- [版本说明](https://github.com/wallpap/PiliAurora/releases)：各版本变更

## 从源码构建

项目使用 [.fvmrc](.fvmrc) 固定 Flutter 版本。构建 Android 还需要 Android SDK 和 JDK 25；构建 Windows 需要安装带有“使用 C++ 的桌面开发”工作负载的 Visual Studio。详细环境要求见[构建与测试说明](doc/build-and-test.md)。

```powershell
git clone https://github.com/wallpap/PiliAurora.git
cd PiliAurora
fvm install
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

## 问题反馈

请通过 [GitHub Issues](https://github.com/wallpap/PiliAurora/issues) 提交问题，并附上系统、设备、应用版本、复现步骤及相关页面信息。播放问题请补充视频编码、清晰度、弹幕设置和硬件解码状态。分享日志前请先移除 Cookie、Token、二维码登录信息及其他账号数据。

## 致谢

PiliAurora 基于 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 开发。PiliPlus 的历史来源包括 [PiliPalaX](https://github.com/orz12/PiliPalaX) 和 [PiliPala](https://github.com/guozhigq/pilipala)。感谢原项目作者、[My-Responsitories](https://github.com/My-Responsitories) 和其他贡献者。项目使用的组件及来源可在 [`pubspec.yaml`](pubspec.yaml) 和 [`third_party/README.md`](third_party/README.md) 中查看。

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE)。第三方组件受各自许可证约束。

# PiliAurora

基于 [PiliPlus 2.1.5](https://github.com/bggRGjQaUbCoE/PiliPlus/tree/2.1.5) 继续开发的 Bilibili 第三方客户端，使用 Flutter 编写，主要维护 Android 和 Windows 版本。

[下载](https://github.com/wallpap/PiliAurora/releases) · [问题反馈](https://github.com/wallpap/PiliAurora/issues) · [许可证](LICENSE)

## 适配平台

- Android（arm64-v8a、armeabi-v7a、x86_64）
- Windows x64

## PiliAurora 的改进

PiliAurora 以 PiliPlus 的客户端功能为基础，重点维护桌面播放和跨平台播放器行为。相较于 PiliPlus 2.1.5，本项目持续进行以下改进：

- **Windows 播放器与弹幕：** 维护桌面视频输出、窗口显示、硬件解码兼容和弹幕渲染，并针对高密度弹幕场景优化渲染开销。
- **Android 播放稳定性：** 改进解码异常后的恢复，并维护屏幕旋转、画面尺寸同步、跳转和独立音轨等播放场景。
- **播放地址回退：** 音频与视频可以独立尝试备用 CDN；独立音轨播放也支持地址回退。
- **日常功能完善：** 增加下载音质选择、分集间字幕状态继承、直播表情弹幕和失效订阅清理等改进。

项目的一个主要使用场景是在 Windows 上使用完整的 B 站客户端，同时获得持续维护的播放器和弹幕体验；Android 版本也共享相关播放改进。具体变更和已知限制见[版本发布说明](https://github.com/wallpap/PiliAurora/releases)。

## 功能

保留并维护 PiliPlus 的主要客户端功能，包括：

- **内容浏览：** 首页推荐、热门、排行榜、视频、番剧、文章、音频、直播和搜索。
- **播放：** 清晰度和音质选择、播放速度、硬件解码设置、弹幕、字幕、分集切换和播放记录。
- **互动：** 评论、动态、关注、粉丝、私信和直播聊天。
- **账号与内容管理：** 多账号、收藏夹、观看历史、稍后再看、番剧订阅和离线下载。
- **扩展功能：** DLNA 投屏、WebDAV 设置备份、SponsorBlock 和 WebView。

功能受 Bilibili 接口、账号权限、平台和具体媒体资源影响。

## 下载

从 [GitHub Releases](https://github.com/wallpap/PiliAurora/releases) 下载 Android APK，或 Windows x64 便携包和安装程序。每个版本的变更与可用附件见对应发布页。

PiliAurora 使用独立的应用标识和数据目录，可以与 PiliPlus 并存。两个应用不会自动共享账号状态、设置、缓存或离线文件。

## 从源码构建

项目使用 [.fvmrc](.fvmrc) 固定 Flutter 版本。Android 构建需要 Android SDK 和 JDK 25；Windows 构建需要安装启用了“使用 C++ 的桌面开发”工作负载的 Visual Studio。详细环境要求和测试命令见[构建与测试](doc/build-and-test.md)。

```powershell
git clone https://github.com/wallpap/PiliAurora.git
cd PiliAurora
fvm install
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

## 问题反馈

请在 [GitHub Issues](https://github.com/wallpap/PiliAurora/issues) 提交问题，附上系统、设备、应用版本、复现步骤和相关页面。播放问题请补充视频编码、清晰度、弹幕设置和硬件解码状态。分享日志前，请移除 Cookie、Token、二维码登录信息和其他账号数据。

## 声明

PiliAurora 是社区独立维护的第三方客户端，与 Bilibili 官方无隶属关系，也未获得其背书。项目使用公开接口，不提供破解内容。使用时请遵守 Bilibili 服务条款及适用法律。Bilibili 名称、商标及相关内容归其权利人所有。

## 致谢

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)：本项目直接基于其 2.1.5 版本继续开发。
- [PiliPalaX](https://github.com/orz12/PiliPalaX) 与 [PiliPala](https://github.com/guozhigq/pilipala)：PiliPlus 的上游项目及历史来源。
- [My-Responsitories](https://github.com/My-Responsitories) 及所有为上游项目和 PiliAurora 作出贡献的开发者。
- Flutter、media_kit、Dio 及其他开源依赖的作者和维护者。

上游源码保留原有版权与许可声明。依赖和移植组件的来源、版权与许可证见 [`third_party/README.md`](third_party/README.md) 及对应组件文件。

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE)。第三方组件遵循各自的许可证。

## 项目文档

- [文档索引](doc/README.md)
- [功能领域地图](doc/features.md)
- [架构说明](doc/architecture.md)
- [构建与测试](doc/build-and-test.md)
- [维护与排障](doc/maintenance.md)

# PiliAurora 项目文档

本文档区是面向第一次接手项目的开发者和 AI 代理的导航入口。它基于 **2026-10-06 的代码**整理，架构说明已同步启动层与下载持久化重构；如果代码、脚本和文档冲突，以代码和实际命令输出为准。

## 推荐阅读顺序

1. [架构总览](architecture.md)：理解启动链路、代码分层和依赖边界。
2. [功能领域地图](features.md)：按用户功能定位页面、API、模型和服务。
3. [构建与测试](build-and-test.md)：准备 Flutter、JDK 25、Android/Windows 工具链并验证。
4. [领域词汇表](glossary.md)：统一 Bilibili、播放器、弹幕和工程术语。
5. [维护与排障](maintenance.md)：修改前检查、典型故障链路和证据记录方式。
6. [开发研究资料](dev/README.md)：阅读 Windows 播放、弹幕、硬件解码和性能实验记录。

## 图示说明

文档中的架构图、领域关系图和构建工具链图使用 Mermaid 编写，放在 Markdown 代码块中，可在 GitHub、GitLab、VS Code Mermaid 插件或其他支持 Mermaid 的阅读器中渲染。图中的节点只引用当前仓库可定位的主要入口；详细行为仍以源码和对应章节为准。
## 项目快照

- **产品**：Flutter/Dart 编写的 Bilibili 第三方客户端。
- **当前维护平台**：Android、Windows x64；不以 iOS、iPad、macOS 或 Linux 为当前目标。
- **上游基线**：PiliPlus 2.1.5；本项目重点维护 Windows 播放/弹幕、硬件解码兼容性、性能稳定性，以及 Android 播放恢复能力。
- **Flutter 入口**：`lib/main.dart`；启动装配在 `lib/app/bootstrap.dart`，根 Widget 在 `lib/app/app.dart`。
- **路由表**：`lib/router/app_pages.dart`。
- **页面**：`lib/pages/`。
- **HTTP API**：`lib/http/`。
- **模型**：`lib/models/`，远端响应模型主要在 `lib/models/remote/`。
- **跨页面服务**：`lib/services/`。
- **播放器**：`lib/plugin/pl_player/`，底层使用 `media_kit` 及平台视频库。
- **平台工程**：`android/`、`windows/`。
- **构建工具**：`tool/build.ps1`、`tool/jnigen.dart`、`lib/scripts/`。
- **测试**：`test/`，按 common、grpc、http、pages、plugin、services、utils、windows 等领域划分。

## 快速定位

| 目标 | 首先阅读 |
| --- | --- |
| 新增页面/路由 | `lib/pages/<领域>/`、`lib/router/app_pages.dart` |
| 新增或修改接口 | `lib/http/<领域>.dart`、`lib/models/remote/<领域>/` |
| 修改播放/解码 | `lib/pages/video/`、`lib/plugin/pl_player/`、`lib/services/diagnostics/player_diagnostics.dart` |
| 修改直播 | `lib/pages/live_room/`、`lib/services/live_stream/`、`lib/http/live.dart` |
| 修改下载 | `lib/pages/download/`、`lib/services/download/`、`lib/http/download.dart` |
| 修改登录/账号 | `lib/pages/login/`、`lib/services/account_service.dart`、`lib/http/login.dart`、`lib/utils/accounts/` |
| 修改设置/本地存储 | `lib/pages/setting/`、`lib/utils/storage.dart`、`lib/utils/storage_key.dart`、`lib/utils/storage_pref.dart` |
| 修改诊断 | `lib/services/diagnostics/`、`lib/services/logger.dart`、`lib/pages/setting/pages/logs.dart` |
| 修改构建 | `tool/build.ps1`、`android/`、`windows/`、`lib/scripts/` |

## 文档规则

- 路径、命令和版本号必须能在当前代码或配置中找到。
- 源码直接确认的内容称为“已确认”；依据目录/调用关系的概括标为“工作模型”；依赖真实设备、网络、显卡或发布环境的内容标为“待实测”。
- 不把不同设备、构建模式、样本和日期的实验数据合并成一条结论。
- 不在文档、日志或截图中记录 Cookie、Token、二维码登录信息、签名密钥、账号数据和未经脱敏的诊断原文。
- `doc/dev/` 保存实验和历史证据；本目录根部保存稳定的架构、功能和开发说明。


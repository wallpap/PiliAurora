# 项目文档

## 使用说明

- [项目介绍与下载](../README.md)：支持平台、主要功能和安装包入口。
- [English README](../README.en.md)：英文项目介绍、下载和构建入口；详细指南仍以中文提供。
- [Windows 播放窗口](windows-playback-windows.md)：弹出视频与直播、排列窗口、调节音量和切换声音来源。
- [弹幕合并与帧率](danmaku-merge.md)：设置入口、匹配规则、字号放大和轨道间距。
- [信息流黑名单屏蔽](content-filtering.md)：设置入口、过滤范围和合作视频作者检查。
- [评论与表情包](comments-and-emotes.md)：评论长按菜单、拉黑用户、表情包管理和内容预览。

## 开发与排障

| 要做的事 | 文档 |
| --- | --- |
| 配置环境、构建应用或选择测试 | [构建与测试](build-and-test.md) |
| 找到一个功能的代码入口 | [功能领域地图](features.md) |
| 理解模块职责和状态所有权 | [架构概览](architecture.md) |
| 查看播放器、弹幕与呈现调度的详细图 | [播放器与弹幕架构图](diagrams/README.md) |
| 追踪启动、播放、下载和消息调用 | [运行流程](runtime-flows.md) |
| 排查问题、收集诊断和复现数据 | [维护与排障](maintenance.md) |
| 修改 Windows 视频输出或超分切换 | [Windows 视频输出](windows-video-output.md) |
| 重建或对照 Windows 帧节奏引擎 | [固定引擎与身份校验](../tool/engine/windows_frame_pacing/README.md) |
| 修改消息、私信与分享 | [消息模块](../lib/services/messaging/README.md) |
| 修改请求账号绑定与 Cookie | [账号拦截器](../lib/utils/accounts/account_manager/README.md) |
| 更新依赖或核对来源与许可证 | [第三方依赖](../third_party/README.md) |
| 查找术语 | [领域词汇表](glossary.md) |

[工具入口](../tool/README.md)说明构建脚本、JNI 生成与依赖检查；[测试目录](../test/README.md)按模块索引自动化测试。[平台探针](../tool/probes/README.md)和[性能实验](../tool/experiments/README.md)各自列出运行条件与验证范围。

## 版本与维护记录

发布附件见 [GitHub Releases](https://github.com/wallpap/PiliAurora/releases)。当前正式版为 [v1.6.4](releases/v1.6.4.md)，上一正式版为 [v1.6.2](https://github.com/wallpap/PiliAurora/releases/tag/v1.6.2)；v1.6.3 为预发布版本，改动已合并到本版。v1.4.3 与 v1.4.3-rc.1 的改动及说明已合并到 [v1.4.4](releases/v1.4.4.md)，未单独发布。历史记录包括 [v1.6.0](releases/v1.6.0.md)、[v1.5.0](releases/v1.5.0.md)、[v1.4.5](releases/v1.4.5.md)、[v1.4.4](releases/v1.4.4.md)、[v1.4.2](releases/v1.4.2.md)、[v1.4.0](releases/v1.4.0.md)、[v1.2.0](releases/v1.2.0.md)、[v1.0.13](releases/v1.0.13.md) 和 [v1.0.7](releases/v1.0.7.md)，其中的测试结果和行为描述对应当时版本。

依赖迁移和精简记录见 [首次迁移验收](../third_party/VALIDATION.md) 与 [依赖精简记录](../third_party/SIMPLIFICATION.md)。Windows mpv 的源码、预编译包和构建流程见 [mpv 构建入口](../third_party/mpv/README.md)。

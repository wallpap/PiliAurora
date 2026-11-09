# 项目文档

## 使用指南

- [Windows 播放窗口](guides/windows-playback-windows.md)：独立窗口、排列和声音控制。
- [弹幕合并与帧率](guides/danmaku-merge.md)：合并规则、字号、帧率与轨道间距。
- [信息流黑名单屏蔽](guides/content-filtering.md)：过滤范围、合作作者检查和请求开销。
- [弹幕、评论与表情包](guides/comments-and-emotes.md)：弹幕点赞、评论菜单和表情包管理。
- [账号与设置备份](guides/data-security.md)：本机存储、JSON 导入导出和 WebDAV 备份。

项目介绍、下载和构建入口见[中文 README](../README.md)及 [English README](../README.en.md)。详细指南以中文提供。

## 开发

| 任务 | 文档 |
| --- | --- |
| 配置环境、构建或选择测试 | [构建与测试](development/build-and-test.md) |
| 恢复或比较自建引擎源码差异 | [引擎与框架差异](development/engine-patches/README.md) |
| 查找功能入口和代码位置 | [功能领域地图](development/features.md) |
| 理解模块职责和状态所有权 | [架构概览](development/architecture.md)、[架构图](diagrams/README.md) |
| 追踪启动、播放、下载和消息调用 | [运行流程](development/runtime-flows.md) |
| 核对播放、弹幕与消息设置的生效时机 | [设置行为](development/settings-behavior.md) |
| 查找项目术语 | [领域词汇表](development/glossary.md) |
| 修改消息、私信与分享 | [消息模块](../lib/services/messaging/README.md) |
| 修改账号请求绑定和 Cookie | [账号拦截器](../lib/utils/accounts/account_manager/README.md) |
| 核对异常处理、返回类型及逐模块检查范围 | [异常与返回类型检查](development/error-handling-review.md) |
| 更新依赖或核对来源与许可证 | [第三方依赖](../third_party/README.md) |

[工具入口](../tool/README.md)介绍构建、代码生成和依赖检查；[测试目录](../test/README.md)按模块列出回归入口。

## 维护与排障

- [维护与排障](maintenance/troubleshooting.md)：诊断入口、调用链和测量方法。
- [Windows 视频输出](maintenance/windows-video-output.md)：原生纹理、超分切换与验证入口。
- [平台探针](../tool/probes/README.md)和[性能实验](../tool/experiments/README.md)：采集命令及运行条件。
- [Windows 帧节奏引擎](../tool/engine/windows_frame_pacing/README.md)：引擎构建身份、补丁和设备验证。
- [历史排障经验](diagnostic-notes/README.md)：过往调查的思路与结果，使用时核对版本和设备。

## 发布与历史

从 [GitHub Releases](https://github.com/wallpap/PiliAurora/releases) 下载发布包，版本改动见 [v1.6.9 更新说明](releases/v1.6.9.md)和[历史版本说明](releases/)。源码默认版本见 [`pubspec.yaml`](../pubspec.yaml)；发布构建使用传入的 tag 和提交数生成版本号。

[依赖迁移验收](../third_party/VALIDATION.md)和[依赖精简记录](../third_party/SIMPLIFICATION.md)介绍依赖调整。Windows mpv 的来源和构建流程见 [mpv 构建入口](../third_party/media_kit_libs_windows_video/UPSTREAM.md)。

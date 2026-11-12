# 项目文档

下载与更新见[中文 README](../README.md#适配平台与下载)；另有 [English README](../README.en.md)。详细指南以中文提供。

## 使用指南

| 任务 | 文档 |
| --- | --- |
| 独立播放窗口、音量、弹幕、空降助手 | [播放与弹幕](guides/playback.md) |
| 黑名单、评论等级、点赞、评论菜单、表情包 | [内容过滤与互动](guides/content.md) |
| 账号与设置导入导出、WebDAV、本机数据 | [账号与设置备份](guides/data-security.md) |
| 提交问题或性能记录 | [问题反馈](../README.md#问题反馈) |

## 开发

首次开发先完成[环境配置和 debug 构建](development/build-and-test.md)，已有环境直接按任务查阅。Agent 遵循根目录 [AGENTS.md](../AGENTS.md)。

| 任务 | 文档 |
| --- | --- |
| 定位功能、源码与测试入口 | [功能领域地图](development/features.md) |
| 理解模块、平台边界和术语 | [架构](development/architecture.md)、[架构图](diagrams/README.md) |
| 追踪启动、请求、播放、下载、消息 | [运行流程](development/runtime-flows.md) |
| 修改账号、状态、分页或异步结果 | [状态管理](development/state-management.md)、[账号拦截器](../lib/utils/accounts/account_manager/README.md) |
| 修改播放状态、原生输出与释放 | [播放状态模型](development/playback-model.md)、[Windows 视频输出](maintenance/windows-video-output.md) |
| 重构图片加载、交互预览与资源释放 | [使用场景与解码路径调查](development/image-usage-audit.md)、[图片加载与预览设计稿](development/image-pipeline-design.md)、[图片模块](../lib/common/widgets/image/README.md) |
| 核对设置的生效时机 | [设置行为](development/settings-behavior.md) |
| 修改桌面标题栏与提示浮层 | [桌面窗口与标题栏](development/architecture.md#桌面窗口与标题栏) |
| 修改消息、私信、未读或分享 | [消息模块](../lib/services/messaging/README.md) |
| 运行检查、构建或制作发布包 | [构建与测试](development/build-and-test.md)、[测试目录](../test/README.md)、[工具入口](../tool/README.md) |
| 更新依赖或定制引擎 | [第三方依赖](../third_party/README.md)、[引擎差异](development/engine-patches/README.md)、[引擎工具](../tool/engine/README.md) |
| 排查设备、性能与内存问题 | [维护与排障](maintenance/troubleshooting.md)、[探针](../tool/probes/README.md)、[实验](../tool/experiments/README.md) |

## 发布与历史

- [GitHub Releases](https://github.com/wallpap/PiliAurora/releases)、[v1.6.9 更新说明](releases/v1.6.9.md)、[历史版本说明](releases/)。
- [历史排障经验](diagnostic-notes/README.md)保留可复用的排查方法，设备结果须按记录条件使用；原始资料保存在本地 `doc/dev/`。
- 依赖调整记录见[迁移验收](../third_party/VALIDATION.md)和[精简记录](../third_party/SIMPLIFICATION.md)。

## 维护文档

用户指南以 UX 为核心，写清入口、操作、生效时机和失败后的操作；开发文档以 DX 为核心，给出源码入口、约束及验证方法；agent 入口以 AX 为核心，按任务链接所需上下文。

同一主题集中维护，短说明优先并入现有章节，重复内容改为链接。模块与工具契约放在代码旁，开发设计放在 `development/`，当前排障方法放在 `maintenance/`，历史结论集中在排障经验中。版本说明记录变化，日志与实验留在本地 `dev/`，可再生产物放在仓库 `build/`。

文档须对应当前源码，工具版本以配置文件为准。删改或合并后更新本索引及引用，检查相对链接与标题锚点；公开设备记录前脱敏并注明验证条件。

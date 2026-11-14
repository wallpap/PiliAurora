# 项目协作

## 开始工作

1. 检查 `git status --short`、`git diff`，保留已有改动；沿调用关系阅读相关代码和测试。
2. 按现有边界做最小修改。功能入口见[功能领域地图](doc/development/features.md)，路由在 `lib/router/app_pages.dart`。
3. 使用 `fvm` 调用固定版本 Flutter/Dart，应用构建走 `tool/build.ps1`（默认 Release，自动装配固定引擎）；环境与验证范围见[构建与测试](doc/development/build-and-test.md)，测试位置见 [`test/README.md`](test/README.md)。
4. 交付时说明改动、实际验证结果和未验证范围。

## 按改动查阅

- 消息、私信、未读角标和私信分享：先读[消息模块](lib/services/messaging/README.md)，核对账号 Session、订阅/租约释放和异步结果语义。
- 状态、分页、账号切换：读[状态管理](doc/development/state-management.md)，核对所有权、迟到响应和释放。
- 播放会话、原生输出：读[播放状态模型](doc/development/playback-model.md)与[架构](doc/development/architecture.md)，分别检查 Android、Windows 路径。
- 弹幕合并、帧率：读[功能地图](doc/development/features.md#弹幕合并与调度)；诊断和设备问题读[维护排障](doc/maintenance/troubleshooting.md)。GPU、MediaCodec 和显示行为需目标设备验证。
- 信息流屏蔽、合作作者检查：读[功能地图](doc/development/features.md#首页与内容发现)。
- 构建、引擎或默认策略：读[默认构建与策略](doc/development/build-defaults.md)，区分已采用修复、诊断实验和设备待验收项；实验资料按[归档约定](tool/experiments/README.md#实验资料归档)更新索引。
- 依赖：先核对 `pubspec.yaml`、`pubspec.lock`、`dependency_overrides` 和[第三方依赖说明](third_party/README.md)，同步来源及许可证登记。
- protobuf/JNI：修改源定义或生成脚本，再按[构建与测试](doc/development/build-and-test.md)中的流程生成产物。

- 文档：按[文档维护约定](doc/README.md#维护文档)组织。用户指南以 UX、开发指南以 DX、agent 入口以 AX 为核心，并核对当前源码；更新导航与链接。实验和设备日志放在本地 `doc/dev/`，临时输出放在 `build/`；公开前核对脱敏与适用范围，标明未验证的设备行为。

# 项目协作

## 开始工作

1. 检查 `git status --short`、`git diff`，保留已有改动；沿调用关系阅读相关代码和测试。
2. 按现有边界做最小修改。功能入口见[功能领域地图](doc/development/features.md)，路由在 `lib/router/app_pages.dart`。
3. 使用 `fvm` 调用固定版本 Flutter/Dart；环境、命令与验证范围见[构建与测试](doc/development/build-and-test.md)，测试位置见 [`test/README.md`](test/README.md)。
4. 交付时说明改动、实际验证结果和未验证范围。

## 按改动查阅

- 消息、私信、未读角标和私信分享：先读[消息模块](lib/services/messaging/README.md)，核对账号 Session、订阅/租约释放和异步结果语义。
- 播放器、弹幕和诊断：读[架构](doc/development/architecture.md)与[维护排障](doc/maintenance/troubleshooting.md)，分别检查 Android、Windows 路径；GPU、MediaCodec 和显示行为需目标设备验证。
- 依赖：先核对 `pubspec.yaml`、`pubspec.lock`、`dependency_overrides` 和[第三方依赖说明](third_party/README.md)，同步来源及许可证登记。
- protobuf/JNI：修改源定义或生成脚本，再按[构建与测试](doc/development/build-and-test.md)中的流程生成产物。

- 文档：使用说明与开发指南须对应当前源码。实验和设备日志放在本地 `doc/dev/`，临时输出放在 `build/`；公开前核对脱敏与适用范围，标明未验证的设备行为。

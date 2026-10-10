# 项目协作说明

## 开始工作

1. 阅读用户请求涉及的代码和文档，并检查 `git status --short`、`git diff`，保留已有改动。
2. 按现有目录和调用关系完成最小范围的修改。页面功能通常位于 `lib/pages/`，API 位于 `lib/http/`，共享服务位于 `lib/services/`，模型位于 `lib/models/`。
3. 按改动选择验证方式。环境准备、构建和测试命令见 [`doc/build-and-test.md`](doc/build-and-test.md)；只运行能覆盖本次改动的检查。
4. 汇报改动文件、实际执行的验证及尚未验证的部分。

## 项目约定

- 使用 `fvm` 调用项目固定版本的 Flutter 和 Dart。版本以 `.fvmrc`、`pubspec.yaml` 和锁文件为准。
- 修改依赖前先检查 `pubspec.yaml`、`pubspec.lock`、`dependency_overrides` 和 [`third_party/README.md`](third_party/README.md)，保持已登记的来源与许可证信息一致。
- protobuf 和 JNI 文件由生成流程维护。修改对应源定义或生成脚本，再按项目命令重新生成。
- 播放器、弹幕和诊断改动需要区分 Android 与 Windows 路径。静态检查和单元测试不能替代目标设备上的 GPU、MediaCodec 或显示行为验证。
- 对外文档只保留稳定的项目说明、使用信息和可复现的贡献指南。实验过程、设备日志、临时数据和未脱敏诊断材料保存在本地资料中；准备公开结论时，先核对事实、适用范围和脱敏情况。
- 文档中的版本、路径、命令和行为以当前源码与配置为准。没有验证的设备行为应明确标注。

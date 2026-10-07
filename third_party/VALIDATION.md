# 依赖迁移验收记录

日期：2026-10-07。环境：Windows，Flutter 3.47.5 / Dart 3.13.4。

## 已确认的变更

- 根依赖声明及锁文件不再含 Git 来源，包括原来音频服务和图片缓存中的传递 Git 依赖。
- 5 个原 Git 包使用发布版；17 个无法等价替换的定制包转为仓库内源码。连同既有的 2 个 Windows 包，登记共 19 个本地版本。
- 每个本地包有独立修订号、来源 SHA、子目录、许可证与保留原因，直接声明、override、登记、包清单和锁文件可自动核对。
- Font Awesome 升级到发布版 11.0.0，应用使用 `FaIconData.data` 对接原来的 `IconData` 组件接口。
- 未升级 Flutter SDK、libmpv、Gradle/AGP 或应用业务 API；窗口标题栏的明确行为变化见 README。

## 实际运行的验证

| 检查 | 结果 |
| --- | --- |
| `flutter pub get` | 成功，锁文件 Git 来源数量为 0。 |
| `flutter pub get --offline --enforce-lockfile` | 成功，已有缓存可按提交的锁文件重现解析。 |
| `dart run tool/check_dependencies.dart` | 通过，19 个本地包的版本、来源和许可证一致。 |
| `flutter test --no-pub` | 335 项通过，其中包含 44 项依赖维护测试及发布版图标组件测试。 |
| `dart analyze tool/check_dependencies.dart test/architecture/dependency_policy_test.dart test/common/widgets/font_awesome_icons_test.dart` | 无诊断。 |
| `flutter analyze --no-pub lib test tool` | 0 error、0 warning、28 info；与迁移前应用代码诊断一致，没有新增应用诊断。该命令不是零诊断通过。 |
| `flutter analyze --no-pub` | 2 error、1 warning、401 info。error/warning 均为迁移前已有的 `doc/dev/local/tool/benchmarks/playback_config_test.dart` 问题；未改该本地实验文件。新增本地上游源码产生 351 项 info，不以关闭检查消除。 |
| `flutter build windows --debug --no-pub` | 成功，输出 `build/windows/x64/runner/Debug/PiliAurora.exe`。 |
| `flutter build windows --release --no-pub` | 成功，输出 `build/windows/x64/runner/Release/PiliAurora.exe`，验证正式编译路径。 |
| `flutter build apk --debug --no-pub` | 成功，输出 `build/app/outputs/flutter-apk/app-debug.apk`。 |
| 工作流 YAML、构建 PowerShell 语法解析 | 通过；未运行远程 CI，也未执行会重置 SDK 的补丁脚本。 |
| `git diff --cached --check` | 通过。 |

## 排查中遇到的问题

1. 初次使用 Font Awesome 10.x 时，双平台编译报告其继承 `final IconData` 不合法。通过升级发布版 11.0.0 并适配 `.data` 解决，不回退到 Git fork。
2. 切换 `audio_session` 来源后，Android 增量构建未产生 Debug 的 `AudioSessionPlugin.class`。单独执行 `:audio_session:compileDebugKotlin --info --rerun-tasks` 成功生成后，重建 APK 成功；没有为此改动包的实现或根 Android 配置。
3. 本地化上游源码后，其 strict lint 开发工具不再作为传递开发依赖解析。显式加入根开发依赖 `lint`，保留上游规则；同时补齐字幕文档模板的闭合标签。

## 验证边界

- 编译通过不等于实机后台媒体通知、GPU/MediaCodec、HDR、PiP、WebView 退出和窗口主题交互已经验证。
- 未构建 Android Release，未展示、修改或提交签名密钥；未上传、推送、合并或发布。
- 本地定制包修订相对上一版本是否递增由维护 review 核对；校验工具不读取 Git 历史，也不校验源码与来源提交逐字相同（本地允许补丁）。
- 普通依赖的进一步更新和定制包回归发布版，应分别作为后续、可独立回滚的变更。

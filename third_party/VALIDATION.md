# 依赖迁移验收记录

日期：2026-10-07。环境：Windows，Flutter 3.47.5 / Dart 3.13.4。包数、版本与测试结果对应首次迁移时的基线；当前维护规则见[依赖指南](README.md)。

## 已确认的变更

- 根依赖声明及锁文件不再含 Git 来源，包括原来音频服务和图片缓存中的传递 Git 依赖。
- 5 个原 Git 包使用发布版；17 个无法等价替换的定制包转为仓库内源码。连同既有的 2 个 Windows 包，登记共 19 个本地版本。
- 每个本地包有独立修订号、来源 SHA、子目录、许可证与保留原因，直接声明、override、登记、包清单和锁文件可自动核对。
- Font Awesome 升级到发布版 11.0.0，应用使用 `FaIconData.data` 对接原来的 `IconData` 组件接口。

## 实际运行的验证

| 检查 | 结果 |
| --- | --- |
| `flutter pub get` | 成功，锁文件 Git 来源数量为 0。 |
| `flutter pub get --offline --enforce-lockfile` | 成功，已有缓存可按提交的锁文件重现解析。 |
| `dart run tool/check_dependencies.dart` | 通过，19 个本地包的版本、来源和许可证一致。 |
| `flutter test --no-pub` | 335 项通过，其中包含 44 项依赖维护测试及发布版图标组件测试。 |
| `dart analyze tool/check_dependencies.dart test/architecture/dependency_policy_test.dart test/common/widgets/font_awesome_icons_test.dart` | 无诊断。 |
| `flutter analyze --no-pub lib test tool` | 0 error、0 warning、28 info；与迁移前应用代码诊断一致。|
| `flutter analyze --no-pub` | 2 error、1 warning、401 info。错误和警告来自迁移前已有的本地实验代码，该代码已在 2026-10-11 的测试与工具整理中移除。新增本地上游源码产生 351 项 info |
| `flutter build windows --debug --no-pub` | 成功，输出 `build/windows/x64/runner/Debug/PiliAurora.exe`。 |
| `flutter build windows --release --no-pub` | 成功，输出 `build/windows/x64/runner/Release/PiliAurora.exe`，验证正式编译路径。 |
| `flutter build apk --debug --no-pub` | 成功，输出 `build/app/outputs/flutter-apk/app-debug.apk`。 |
| 工作流 YAML、构建 PowerShell 语法解析 | 通过。 |
| `git diff --cached --check` | 通过。 |

> 2026-10-17 的测试清理移除了仅验证第三方图标接口的 `font_awesome_icons_test.dart`；上表保留当时的验证记录。

## 排查中遇到的问题

1. 初次使用 Font Awesome 10.x 时，双平台编译报告其继承 `final IconData` 不合法。通过升级发布版 11.0.0 并适配 `.data` 解决。
2. 切换 `audio_session` 来源后，Android 增量构建未产生 Debug 的 `AudioSessionPlugin.class`。单独执行 `:audio_session:compileDebugKotlin --info --rerun-tasks` 成功生成后，重建 APK 成功。
3. 本地化上游源码后，其 strict lint 开发工具不再作为传递开发依赖解析。显式加入根开发依赖 `lint`，保留上游规则；同时补齐字幕文档模板的闭合标签。

## 验证边界

- 本地定制包修订相对上一版本是否递增由维护 review 核对；校验工具不读取 Git 历史，也不校验源码与来源提交逐字相同（本地允许补丁）。
- 普通依赖的进一步更新和定制包回归发布版，应分别作为后续、可独立回滚的变更。

## 首轮直接迁移到发布版的包（历史记录）

| 包 | 根约束 / 锁定版本 | 取舍 |
| --- | --- | --- |
| audio_session | `^0.2.4` / `0.2.4` | Dart 和原生实现与来源相同；回到发布版 Android Gradle/AndroidX 配置。 |
| font_awesome_flutter | `^11.0.0` / `11.0.0` | 使用支持 final IconData 的正式字体包；调用使用 FaIconData.data 对接现有 IconData 接口，不再依赖 fork 的资源生成方式。 |
| window_manager | `^0.5.2` / `0.5.2` | 使用正式版；应用暗色而系统亮色时，标题栏遵循上游系统暗色条件，不再保留 fork 的单行行为差异。 |
| media_kit_libs_video | `1.0.5` / `1.0.5` | 使用发布版平台聚合包；Android/Windows 原生库仍由本地 override 提供。 |
| media_kit_native_event_loop | 传递依赖 / `1.0.9` | 使用实现一致的发布版事件循环；移除 Git override。 |

未将所有 fork 机械替换为同名发布版：`get` 等包的独立 UI 类型与 `rawValue`/转场扩展、弹幕绘制、HTML 选择器、旋转阈值和原生播放接口都已经被应用使用。逐包保留原因以登记表为准。

# 本地定制依赖

本项目不再从 Git 分支解析 Dart/Flutter 依赖。普通依赖使用 pub.dev 版本约束，应用提交 `pubspec.lock`；无法由发布版替代的定制实现放在本目录，随应用源码一起进行版本控制。

## 简单特性内化

第二阶段已将按标签节流、尾沿防抖和 UUID v4 内化为小型标准库实现，并将图片缓存接口包合并回主包。当前本地包登记为 18 个；合并来源继续登记和保留许可证。范围、真实依赖减少量及验证见 [SIMPLIFICATION.md](SIMPLIFICATION.md)。

## 版本与来源

- `dependencies.json` 是本地包的登记表，记录本地版本、来源版本、仓库、完整提交 SHA、来源子目录、许可证和保留原因。
- 根 `pubspec.yaml` 的直接定制依赖使用精确版本（例如 `1.1.11+piliaurora.1`），`dependency_overrides` 将实际源码指向本目录。传递定制包也必须登记和 override。
- 每个本地包的 `pubspec.yaml` 使用独立的 `+piliaurora.N` 修订号，并设置 `publish_to: none`。这不是同名 pub.dev 版本的镜像。
- 根版本声明本身不能约束 path override；`dart run tool/check_dependencies.dart` 会检查登记、本地声明和锁文件的一致性，并拒绝任何 Git 来源。
- 每个包保留原许可证和来源版权信息。新导入包收录生产源码、构建配置和必要资源，不收录上游示例、测试、开发缓存及 Git 元数据。既有两个 Windows 包保持原有补丁。导入源码清理行尾空白，并补齐字幕文档模板闭合标签，不改写实现。

## 首轮直接迁移到发布版的包（历史记录）

| 包 | 根约束 / 锁定版本 | 取舍 |
| --- | --- | --- |
| audio_session | `^0.2.4` / `0.2.4` | Dart 和原生实现与来源相同；回到发布版 Android Gradle/AndroidX 配置。 |
| font_awesome_flutter | `^11.0.0` / `11.0.0` | 使用支持 final IconData 的正式字体包；调用使用 FaIconData.data 对接现有 IconData 接口，不再依赖 fork 的资源生成方式。 |
| window_manager | `^0.5.2` / `0.5.2` | 使用正式版；应用暗色而系统亮色时，标题栏遵循上游系统暗色条件，不再保留 fork 的单行行为差异。 |
| media_kit_libs_video | `1.0.5` / `1.0.5` | 使用发布版平台聚合包；Android/Windows 原生库仍由本地 override 提供。 |
| media_kit_native_event_loop | 传递依赖 / `1.0.9` | 使用实现一致的发布版事件循环；移除 Git override。 |

未将所有 fork 机械替换为同名发布版：`get` 等包的独立 UI 类型与 `rawValue`/转场扩展、弹幕绘制、HTML 选择器、旋转阈值和原生播放接口都已经被应用使用。逐包保留原因以登记表为准。未发布的 `flutter_sortable_wrap 1.0.6`、`material_design_icons_flutter 7.0.7447` 也不伪装成 hosted 版本。

## 更新流程

### 普通发布依赖

根 `dependencies` 和 `dev_dependencies` 的 hosted 包统一使用精确版本号，不使用 `^`、区间或 `any`；根 hosted override 也遵循相同规则。版本取自已验收的 `pubspec.lock`，不是自动选择最新发布版。SDK 包由 `.fvmrc` 管理，第三方包自己的传递约束不机械改写，传递解析结果由锁文件和 `--enforce-lockfile` 固定。

1. 修改目标包的精确版本号，再执行 `flutter pub get`，不要仅执行 `pub upgrade`（精确约束不会自动升级）。
2. 审核 `pubspec.lock`，避免无关依赖更新；依赖校验必须确认根声明和锁定版本逐字一致，包括预发布与 build 后缀。
3. 执行依赖检查、相关测试和对应平台构建后，一起提交声明与锁文件。

### 本地定制包

1. 核对登记中的上游仓库、提交和子目录，在独立临时目录取新源码；不要直接从浮动分支覆盖本目录。
2. 审查上游差异并移植仍需要的本地修改。保留所有许可及版权说明，核对资源和原生库校验值。
3. 递增 `+piliaurora.N`（有上游升级时同时更改基础版本），同步根直接依赖版本、登记和包的 `UPSTREAM.md`。不要只改根版本号而保留旧源码。
4. 如该包仅为传递依赖，仍需更新本地版本和登记；根 override 不得遗漏。
5. `flutter pub get`，然后运行：

   ```powershell
   dart run tool/check_dependencies.dart
   flutter analyze --no-pub lib test tool
   flutter test --no-pub
   flutter build windows --debug --no-pub
   flutter build apk --debug --no-pub
   ```

6. 将单个更新及其适配、测试作为可独立回滚的提交。新版本若可以去掉定制，则切回已验证的发布版，并同时移除 override、本地源码和登记。

构建成功不代表后台通知、实际 GPU/MediaCodec、窗口主题及 WebView 退出已经完成实机验证；这些交互仍需人工回归。`third_party` 的上游检查告警应如实记录，不通过关闭检查或削弱测试来清零。

## 原生二进制与 SDK

本次未升级 Flutter、Gradle/AGP 或 libmpv。Android 原生库仍使用来源的版本化下载地址与 SHA-256；Windows 继续使用既有 `20260819` 固定归档及 DLL/导入库校验。Flutter SDK 与 `material_ui` 的现有补丁脚本不属于 Git 依赖解析，本次未重写该流程，也不调用会重置 SDK 的补丁脚本进行验证。

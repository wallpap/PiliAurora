# 第二阶段：依赖精简与内化

日期：2026-10-07。基线：`89e169dd7`，分支：`chore/versioned-dependencies`。

## 取舍与范围

本轮只替换使用面很小、能通过标准库实现并充分测试的特性，不自行实现加密、解码器、原生平台插件或通用布局框架。内化不是把第三方整个工具箱复制进应用；只保留实际使用的语义。

| 原依赖 | 实际使用 | 当前归属 |
| --- | --- | --- |
| easy_debounce | 按字符串标签立即执行一次、冷却期丢弃重复调用、取消标签 | `lib/utils/rate_limiter.dart` 的 `ActionThrottle`，不实现未使用的 onAfter/count/cancelAll。 |
| stream_transform | 搜索、提及、话题、设置筛选及超级留言面板的尾沿防抖 | 标准库 Timer 的 `Debouncer`，共用 `lib/common/widgets/debounced_state.dart`。页面不再为通用防抖而依赖搜索控制器。 |
| uuid | 两处 UUID v4 字符串：私信 devId 与 Buvid3 的 UUID 部分 | `lib/utils/random_id.dart`，默认使用 `Random.secure()`，只实现 v4。 |
| cached_network_image_platform_interface_ce | 仅本地图片缓存主包引用的模型与 IO 加载契约 | 合并至 `cached_network_image_ce/lib/src/cache_api` 与 `cache_api.dart`，对应用的公开导出不变。 |
| json_annotation、package_info_plus | 应用源码没有直接导入，实际由其他包消费 | 移除根直接声明，由消费方管理其约束；锁定版本不变。 |

### 保留的行为

- 标签冷却按时间计算，不等待异步动作完成；先登记标签，再调用动作，阻止同步重入。同步异常仍向调用方传播，且不绕过冷却窗口。
- 防抖只发送安静期之后的最后一个值，包括 null；支持现有 200/300 ms 覆盖。重新初始化、关闭控制器或卸载 State 时取消尚未开始的任务，不宣称取消已开始的网络请求。
- UUID 保持小写、连字符和 v4/variant 位；Buvid3 保持大写 UUID、5 位数字和 infoc 后缀。注入 Random 参数用于确定性测试，生产调用均使用安全随机默认值，不用于替代认证 Token 或加密算法。
- 缓存的六个模型源码和原 MIT 许可证已与来源提交逐字比对（只统一比较行尾），内容未改。仅调整库归属及导入/导出路径。

UUID 位布局依据：[RFC 9562 §5.4](https://www.rfc-editor.org/rfc/rfc9562.html#section-5.4)。

## 缓存接口包合并与许可

主包修订从 `4.6.4+piliaurora.1` 递增为 `.2`。原接口包不再是独立 Pub 包，但来源元数据、说明和许可证保留在主包 `upstream/platform_interface`，没有丢弃文件内容。

- 历史清单和分析配置改名为 `pubspec.upstream.yaml`、`analysis_options.upstream.yaml`，不参与包解析及分析。
- `third_party/dependencies.json` 的 `merged_sources` 记录原包名、来源版本、仓库、完整 SHA、子目录和保留原因。
- 主包的 licenses 同时登记合并来源许可证；依赖检查工具校验合并来源 SHA、源码目录范围、许可证存在性及主包许可证登记，防止合并后遗失出处。

## 实际减少了什么

- 根直接运行依赖：**83 → 78**。
- 独立本地 path 包：**19 → 18**。
- 解析树包数（包含根项目、开发依赖）：**252 → 250**。
- 从整个锁文件消失的包只有 **easy_debounce** 和 **cached_network_image_platform_interface_ce**。
- uuid 仍供 saver_gallery/share_plus_platform_interface 使用；stream_transform 仍供构建工具使用；json_annotation 和 package_info_plus 仍供其他包使用。因此不将“移除直接声明”描述为“彻底删除整个依赖”，也不据此宣称安装包体积或运行性能已改善。
- 除本地缓存修订号外，其他解析版本保持不变；未引入新生产或开发依赖。

## 验证

- 全量 `flutter test --no-pub`：370 项通过，较本轮基线增加 35 项（24 项替代实现与生命周期测试、8 项合并来源校验、3 项依赖归属守卫）。既有图片生命周期测试继续通过。
- 新模块、校验工具及其测试的定向 Dart 分析无诊断。
- `flutter analyze --no-pub lib test tool`：0 error、0 warning、28 项既有 info；未关闭检查。
- `dart run tool/check_dependencies.dart`：通过，18 个本地包与合并来源、版本、许可证一致。
- 工作流 YAML 已解析，新增内化回归测试与原迁移测试一并在 CI 执行；使用单条 folded 测试命令，保持独立退出状态。未运行远程 CI。

- `flutter pub get --offline --enforce-lockfile`：成功，现有缓存按锁文件复现解析。
- `flutter build windows --release --no-pub`：成功，输出 `build/windows/x64/runner/Release/PiliAurora.exe`。
- `flutter build apk --debug --no-pub`：成功，输出 `build/app/outputs/flutter-apk/app-debug.apk`。
- 构建日志仍有既有插件的 compileSdk 覆盖和 flutter_volume_controller KGP 兼容提示，未通过关闭工具掩盖。

真实页面交互、实机后台通知、GPU/MediaCodec、HDR/PiP 仍不在本轮验证范围内。未构建 Android Release，未安装到设备，未执行 SDK 重置或远程发布。

## 后续维护

新增简单工具应优先使用这里的 Timer 工具和 UUID v4 生成器；新增原生功能仍由已有插件负责。不要为“依赖数更少”再造 collection、加密、图片解码或播放引擎。增加 UUID 其他版本或改变节流/防抖语义前，应先证明应用确实需要，并补充对应契约测试。


# 第三阶段：精确版本与两个专用模块

日期：2026-10-07。接手基线：`51e5e8dda`，继续使用 `chore/versioned-dependencies`。

## 精确固定根声明

- 将 69 个浮动 hosted 约束改为原锁文件中的精确版本，覆盖生产与开发依赖，包括原先 `material_ui` 的区间；不查找或自动升级所谓最新版。
- 根 `dependencies`、`dev_dependencies`、hosted `dependency_overrides` 不允许范围、caret 或 `any`，锁文件的 source 和 version 必须与声明一致，预发布和 build 后缀也不能漂移。
- 本地定制直接依赖同样必须精确对应登记版本，不能以兼容区间绕过。SDK 包仍由 `.fvmrc` 与 SDK 声明管理；第三方包的传递兼容区间保留，解析结果通过提交的锁文件和 `--enforce-lockfile` 固定。
- 固定版本这一提交没有改变锁文件。维护更新流程见 `third_party/README.md`，新增 22 项策略测试。

## 日志内化

- 应用实际只使用 d/i/w/e 四个等级，统一通过 `AppLogger` 接入现有 `Diagnostics`。过滤发生在消息格式化之前，关闭等级时不构造日志字符串；结构化消息也先脱敏，再进入控制台或落盘。
- 不再同时使用第三方 Logger 的过滤、打印与输出流水线。可选控制台回调只在 Debug 应用中注入；日志和错误信息、堆栈的敏感字段经过现有脱敏入口。
- `catcher_2` 改为宿主 `ReportLog` 回调，不再要求传入第三方 `Logger`。仅保留页面与 Report 使用的堆栈过滤，删除未消费的颜色、边框和通用打印器实现。无回调时不默认向控制台输出异常内容。
- 本地修订升为 `2.1.9+piliaurora.2`，同步根声明、登记、来源说明和锁文件；异常钩子、Report JSON 格式与设备信息收集未改。
- `logger` 不仅移除直接声明，也从整个解析树移除。新增应用日志与捕获器契约测试覆盖等级、过滤前不格式化、控制台/持久化脱敏、堆栈过滤和 Report 格式。

## WebDAV 设置客户端内化

- `WebDavSettingsClient` 复用已有 Dio，只实现 Basic Auth、逐级 MKCOL、PUT 与 GET，不实现 XML 目录查询、Digest、文件管理或未使用的扩展接口。
- endpoint 基路径与文件名按 URI 段组合；空格、中文、百分号、问号和井号按文件名编码。禁止路径穿越和地址中携带明文认证信息、查询或片段，不跟随重定向。
- 设置页面已从初始化凭据的单例缓存改为每次操作快照与独占客户端；操作结束始终关闭连接池。恢复直接 GET，不在服务器上创建目录。
- **上传不再先 DELETE。** PUT 请求直接创建/替换备份，消除客户端在上传失败前主动删除旧备份的窗口；不保证任意第三方服务器 PUT 的事务性或断电原子性。
- 网络失败只向 UI 暴露请求方法和 HTTP 状态，不暴露 Dio 请求头、响应正文或完整 URL。URL 配置错误也走页面脱敏输出。
- 保留原来实际使用的 Basic Auth；不新增 Digest 等历史上未启用的模式。由于只实现设置用途，公开通用文件管理接口不作为兼容目标。
- 新增适配器契约测试和真实 Dio + 独占 loopback HttpServer 的 UTF-8 上传/恢复回归；测试不访问用户 WebDAV 或共享资源。
- Dio 行为通过 Context7 的官方仓库文档及当前安装源码核对；MKCOL/PUT 语义对照 RFC 4918 §9.3、§9.7。未复制 webdav_client 源码。

## 数量与解析变化

| 指标 | 接手前 → 本轮完成 |
| --- | --- |
| 直接运行依赖（包含 SDK） | **78 → 76** |
| 独立本地包 | **18 → 18** |
| 解析树包数（包含根项目及开发依赖） | **250 → 248** |
| 真正移除的锁文件包 | **logger、webdav_client** |

除了 catcher_2 本地修订号，保留包的解析版本不变；没有新增生产或开发依赖。XML 等仍被其他依赖使用，未宣称随 WebDAV 全部移除。本轮没有做体积或性能基准，不以减少依赖数量替代性能测量。

## 验证结果与边界

- 全量 `flutter test --no-pub`：**442 项通过**，相对接手基线增加 **72 项**。不是仅跑新增测试。
- `flutter analyze --no-pub lib test tool`：**0 error、0 warning、28 项既有 info**；本轮产生的提示已修复，没有关闭规则。
- 内化模块、调用适配、相关测试及 catcher_2 生产源码的定向 Dart 分析：无诊断。
- `dart run tool/check_dependencies.dart`：通过；精确版本、本地修订、来源和许可证保持一致。
- `flutter pub get --offline --enforce-lockfile`：按本地缓存复现锁文件；不需要拉取浮动 Git 依赖。
- Windows Release 与 Android Debug APK 构建成功；Android 构建仍有既有插件 compileSdk 覆盖和 flutter_volume_controller KGP 提示，没有通过改动共享 SDK 或关闭检查消除。
- 两个平台 CI 工作流加入日志、捕获器和 WebDAV 回归测试，YAML 已解析；未运行远程 CI。
- 未推送、合并、发布或读取签名密钥。Android Release、真实 WebDAV 厂商服务、页面手动交互和实机原生功能尚未验证。
- 未执行会重置共享 Flutter SDK、删除 Pub 缓存的历史补丁脚本；material_ui 已精确固定，但 SDK/包缓存补丁流程本身仍属于下一步可单独治理的范围。

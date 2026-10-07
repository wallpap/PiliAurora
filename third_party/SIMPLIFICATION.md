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

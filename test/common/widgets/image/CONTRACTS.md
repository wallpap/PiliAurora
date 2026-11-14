# 图片重构的测试契约

[设计稿](../../../../doc/development/image-pipeline-design.md)对应的行为契约如下。测试使用本地夹具与真实 `ui.Image`，不依赖用户日志或网络；受控 decoder 验证请求和释放协议，原生像素与设备性能另行验证。

## 自动化契约

| 测试 | 对外可观察行为 |
| --- | --- |
| `image_resources_contract_test.dart` | 有界原生并发、取消后真实完成才归还名额、取消前未启动工作不执行、预处理隔离、错误原因/堆栈、关闭排空、优先级与 owner 公平性 |
| `image_frame_request_contract_test.dart` | `loadImageFrame` 一次性第 0 帧、codec 关闭与输出所有权、迟到输出释放、与 Provider 共用准入、本地 Provider 保留框架 decoder callback |
| `image_sampling_contract_test.dart` | 不同 BoxFit/宽高比/DPR 的足够采样、低分辨率不放大缓存、正文长图不暗中套 1MP、物理尺寸向上取整 |
| `image_source_store_contract_test.dart` | 固定快照字节、并发/重叠租约共享、最后租约结束后新版本、清理不删除活动快照与用户文件、失败后重试 |
| `content_image_contract_test.dart` | 原图几何独立于解码分辨率、滚动位置稳定、加载与动画许可分离、禁止加载不 resolve、旧来源迟到不覆盖当前来源 |
| `../../../pages/emote/image_demand_test.dart` | 600 个普通图片表情只建立可见及有限邻域、滚动末尾仍有界、选择回调与文字表情语义保留 |
| `image_entry_integration_test.dart` | 真实 PNG 的未知比例网络 cover、本地 cover、外层 ResizeImage 元信息、失败本地键重试；生产 HTML CSS 标记使用应用图片入口 |
| `content_viewer_integration_test.dart` | 换采样保持视口、窗口调整保持焦点/密度，滚轮、捏合、平移、双击和惯性统一发出需求 |
| `region_content_session_test.dart`、`region_extension_test.dart` | 同版本有界基础/细节、层级及重叠、跨会话预算、取消在途租约、失败不完整回退、绘制退役和 detach/reattach 排空 |
| `native_backend_extension_test.dart`、`native_demand_base_test.dart` | 真实 worker 的输出准入、需求基础层、关闭排空与来源释放 |
| `native_content_image_test.dart` | 网络/本地 Gallery 接线、隐藏关闭和恢复、GIF 签名分流不启动 worker、动画/方向/超容量回退、超大 WebP 中间层边界、错误后依赖变化不转完整帧 |
| `native_fidelity_test.dart` | 真实 Flutter 显示像素、透明边界、有损 WebP 非零裁剪、ICC 与基础/细节交接 |

调度通过 `result/cancel/drained` 检查真实完成与取消；帧入口为 `loadImageFrame`、`LocalImageProvider`，采样和快照位于内部 `image/src/`，ContentImage 通过 ImageProvider 注入来源。缓存根、显示 clone 与框架引用分别持有，测试入口保持在模块边界内。

2026-11-13 的统一回归覆盖图片核心、真实入口、Viewer、区域协议、普通表情、弹幕、雪碧图及外围缓存、文章、音频和图片操作：207 项通过，Flutter 3.47.5，耗时 23 秒，日志为 `build/image-pipeline-final-tests.log`。

```powershell
fvm flutter test --no-pub test/common/widgets/image/ test/pages/emote/ test/pages/danmaku/live_queue_test.dart test/utils/image_source_cache_test.dart test/utils/cache_results_test.dart test/pages/article/ test/services/audio_handler_lifecycle_test.dart test/utils/image_actions_test.dart test/utils/image_save_results_test.dart test/pages/whisper_detail/image_send_results_test.dart test/plugin/pl_player/preview_image_cache_test.dart test/pages/live_room/emote_danmaku_test.dart --reporter expanded
```

该阶段 `fvm flutter analyze --no-pub --no-fatal-infos` 为 0 error、0 warning，保留 12 条 `avoid_slow_async_io`；38 个 Dart 文件格式检查、flutter_html 独立分析、依赖及相对链接检查通过。文件访问保持异步。以上是当日结果，平台构建与后续修改的覆盖见下文。

## 必须保留的已有回归

按变更复用生命周期、动画恢复、ImageCache、首帧、decoder callback、ResizeImage、裁剪 URL 和 retained layer 用例，以及播放器 `preview_image_cache_test.dart`、直播 `emote_danmaku_test.dart`、普通表情控制器和受影响页面。

直接 Provider、CSS 列表标记、本地封面/附件、雪碧图及弹幕需覆盖真实接线。表情回归以真实 ScrollPosition 到达末尾并点击末项，保持 600 个候选中少于 100 个活动/邻域条目及选择语义。单帧 Provider 与 12 帧动画消费者分别建夹具，首帧交付不绑定动画时钟。

## 区域后端和设备验收

2026-11-14 Windows Gallery 已接入 WIC 静态 JPEG/PNG 与 libwebp 静态 WebP。受控后端测试预算、层级和交接协议，真实 worker 测试像素、接线、来源释放及进程排空。

Windows 先生成确定性夹具并构建 worker：

```powershell
uv sync --locked
uv run --locked python tool/probes/windows/image_region_probe.py
uv run --locked python -m unittest discover -s tool/probes/windows -p image_region_probe_test.py -v
fvm flutter test --no-pub test/common/widgets/image --concurrency 2
```

产物位于 `build/probes/image-region/`，可通过 `REGION_TEST_WORKER` 和 `REGION_FIXTURES` 覆盖。缺少 Windows worker 时原生 Flutter 用例会跳过，须单独记录，不能计入通过覆盖。固定 libwebp 来源和裁剪修复见[上游登记](../../../../third_party/libwebp/UPSTREAM.md)。

| 验证阶段 | 已有结果与范围 |
| --- | --- |
| 图片目录 | 145 项通过，包含 8192×6144 WebP 容量回退，以及 worker 异常后依赖更新仍保持错误状态 |
| Flutter 像素 | 12 项、36 个显示区域，最大通道差 3，包含透明边界与有损 WebP 裁剪 |
| 原生探针 | 透明有损 WebP 非零原点裁剪、非法区域和动画/方向排除共 3 项通过 |
| 静态检查 | adapter/Widget 定向分析通过；图片目录 0 error、0 warning，保留 9 条已有异步 I/O 提示 |
| Windows 构建 | 标准及固定 patched engine Release 构建通过 |
| 最后签名分流 | `native_content_image_test.dart` 与 `native_backend_extension_test.dart` 共 8 项通过，3 文件定向分析通过；此改动后未重建 Release 或复测性能 |

缺少 WIC codec 的格式回退完整帧，并与独立 Flutter 解码参照比较。当前 Windows 引擎也不支持测试 AVIF 夹具，回退保留同样的格式错误。

本机压力峰值与延迟见[图片模块验证边界](../../../../lib/common/widgets/image/README.md#验证边界)。后续设备验证覆盖：

- 一般/高/超高/低分辨率、GIF、长图、动画 WebP、EXIF 方向、透明边界与接缝。
- 文章和私信阅读、网格预览、本地文件、翻页缩放拖动、窗口变化、离页和重复循环。
- 通知封面与 Bitmap 缓存、快捷方式、视频交接、截图及离屏导出的矩形完整性。
- 固定来源、物理视口、滤镜和缓存条件，比较冷热首屏、帧时间、真实峰值、退出资源与磁盘；未测 native/GPU 成本保留未知。

# 图片重构的测试契约

本轮依据[第三版设计稿](../../../../doc/development/image-pipeline-design.md)先提交预期测试，再提交实现。测试不依赖用户日志或真实网络。首次提交允许因新入口尚不存在而失败；实现提交须使这些预期与已有图片回归通过，不能通过 skip、删断言或改低画质预期取得通过。

2026-11-12 的实现前验证：普通表情用例实测一次建立 600 张图片，未满足少于 100 个活动/邻域条目的预期；文字表情选择用例通过。五个新契约文件因尚无对应生产入口而加载失败，符合本次测试先行的红灯状态。新文件的 Dart 语法/格式检查已完成，后续实现提交须记录转绿结果。

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
| `region_content_session_test.dart` | 生产门控、同版本有界基础/细节、层级及重叠、跨会话预算、取消在途租约、失败不完整回退、绘制退役和 detach/reattach 排空 |

本地受控 decoder 返回真实 `ui.Image` 并记录请求/释放，避免用伪像素对象证明 native 释放。缓存、已交付显示 clone 和框架引用各有自己的生命周期。注入受控 decoder 只验证协议，不证明真实格式峰值或 GPU 回收。

本轮测试用以下小型 seam 固定可测契约：共享资源调度返回 `result/cancel/drained`；帧入口为 `loadImageFrame` 和 `LocalImageProvider`；显示采样及快照仓库放在内部 `image/src/`；内容 Widget 允许通过 ImageProvider 注入真实/受控来源。实现可以细分内部文件，不把测试所用内部 seam 扩散到业务页面。

2026-11-13 实施阶段增加了关闭中的真实 codec/frame、文件晚到/排队期限、source acquire/release/clear 竞态及独立任务租约回归。普通 Provider 用例的假 codec 改为单帧，动画单帧消费者仍为 12 帧，避免夹具将首帧交付错误地绑定到动画时钟。表情末尾验证直接使用当前包的真实 ScrollPosition，随后点击末项，保留少于 100 和选择语义断言。

2026-11-13 最终统一回归：207 项全部通过，耗时 23 秒。覆盖本目录完整图片契约/生命周期/真实入口/Viewer/区域协议，普通表情、弹幕队列、播放器雪碧图及受影响缓存、文章、音频和图片操作回归。固定 Flutter 3.47.5；本地详细日志为 `build/image-pipeline-final-tests.log`。这是受控环境自动化结果，未包含下述 Windows/Android 设备性能验收。

```powershell
fvm flutter test --no-pub test/common/widgets/image/ test/pages/emote/ test/pages/danmaku/live_queue_test.dart test/utils/image_source_cache_test.dart test/utils/cache_results_test.dart test/pages/article/ test/services/audio_handler_lifecycle_test.dart test/utils/image_actions_test.dart test/utils/image_save_results_test.dart test/pages/whisper_detail/image_send_results_test.dart test/plugin/pl_player/preview_image_cache_test.dart test/pages/live_room/emote_danmaku_test.dart --reporter expanded
```

本轮改动范围的 `fvm flutter analyze --no-pub --no-fatal-infos` 为 0 error、0 warning，保留 12 条 `avoid_slow_async_io` 提示；文件状态检查保持异步，避免为消除风格提示引入 UI 线程同步 I/O。38 个 Dart 文件格式检查、flutter_html 修改文件的独立分析、依赖维护验收和文档相对文件链接检查均通过。尚未运行平台构建和真实设备性能验收。

## 必须保留的已有回归

复用本目录生命周期、动画恢复、ImageCache、首帧交付、decoder callback、ResizeImage、裁剪 URL 与 retained layer 用例；另运行播放器 `preview_image_cache_test.dart`、直播 `emote_danmaku_test.dart`、普通表情控制器及受影响页面用例。

直接 Provider、CSS 列表标记、本地封面/附件、雪碧图及弹幕接入后须增加对应真实入口回归。新入口协议通过不能替代实际调用点接线；实现阶段可补充集成测试，但不得降低上述预期。

## 区域后端和设备验收

设计尚未选定生产区域后端，先实现并验证内容/资源生命周期并保持能力门控。区域协议实现后补充受控后端测试：基础层覆盖、视口合并、同版本/坐标复用、旧批次交接、基础/细节/在途输出统一预算、取消和失败不转为超大整图解码。没有真实后端时不能将受控适配器作为已支持原生区域解码交付。

Windows/Android 必须再验证以下矩阵，作为启用区域能力的门槛，不使用固定 skip 用例冒充覆盖：

- 一般分辨率、高分辨率、GIF、长图、超高分辨率、低分辨率；补充动画 WebP、EXIF 方向、透明边界和瓦片接缝。
- 文章/私信点击前阅读、网格点击后预览、本地图片、切页/缩放/滚动/窗口变化、离页与重复循环。
- 原生通知封面降采样及 Bitmap 缓存、快捷方式、视频输出交接、生成截图、离屏导出矩形完整性。
- 同源/物理视口/滤镜/缓存条件对照，冷/热首屏、p95 帧耗时、真实峰值、退出后资源与磁盘；未经验证的 native/GPU 成本保留未知。

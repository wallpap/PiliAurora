# 图片模块

2026-11-14。架构取舍见[设计稿](../../../../doc/development/image-pipeline-design.md)，实现前的调用清单见[调查快照](../../../../doc/development/image-usage-audit.md)。

## 入口与所有权

| 入口 | 职责 |
| --- | --- |
| `cached_image.dart` | CachedImage、CachedImageProvider、LocalImageProvider、框架 decoder callback 和 ImageCache 协作；保留默认 Provider 相等性及外层 ResizeImage |
| `content_image.dart` | 订阅、加载/动画需求、稳定源几何、显示会话；`image_viewer/content_viewer.dart` 适配手势视口 |
| `image_resources.dart` | binding 内共享调度，默认两项原生并发、最多一项重预处理，可见优先、owner 轮转与等待老化；测试用 runWith 隔离，runtime 身份不进入 Provider 键 |
| `src/image_source_store.dart`、`src/image_sampling.dart` | 不可变快照租约；按实际元信息、BoxFit 和有效 DPR 推导采样，尺寸向上归档 |

`loadImageFrame(File)` 返回 result/cancel/drained。result 是调用者独占的第 0 帧，使用后 dispose；codec 取帧后关闭。取消保留原生名额到真实完成，迟到图像由请求释放。`loadNetworkImageFrame` 合并编码文件读取后复用此流程；isCurrent 在取得文件和准入后检查弹幕期限。

Provider 的图像由 ImageStream/ImageInfo 管理，消费者释放自己的 ImageInfo。ContentImage 在绘制结束后释放替换的旧帧，动画和无监听缓存交接由同一私有 completer 管理。ImageLoadingScope 与 TickerMode 独立，允许静态导出；Gallery 邻页可加载，只有当前页播放动画。正文滚动时计算祖先裁剪交集，静态头像不做全局逐帧扫描。

sourceSize 仅作布局提示，实际 decoder 原始尺寸优先；ResizeImage 的缩小帧不作为原始元信息。cover 在 decoder callback 内按真实比例采样，不新增预探测 codec。未知比例的 CDN 请求保留来源，可能下载更多编码字节。

雪碧图保留原坐标和 3 项/24MiB 缓存，弹幕保留期限与任务/字节配额及文本降级。图片表情使用惰性网格并播放动画，文字和混合历史保留 Wrap。通知封面由音频插件单独配置为 512×512，不占 Dart 解码队列。

## 区域协议与门控

Windows 的 ContentImage 有交互视口、未指定缩小目标且来源为网络缓存或本地文件时，选择同目录的 `piliaurora_image_worker.exe`，目前用于 Gallery。worker 缺失、普通正文、封面和其他平台均走完整帧。

`src/native_worker_backend.dart` 为每份不可变来源启动独立 CPU worker：WIC 处理静态 JPEG/PNG，固定 libwebp decoder 处理静态 WebP。有界管道输出预乘 RGBA，由普通 `ui.Image` 绘制；没有外部 GPU 纹理或 raw 临时文件。来源租约保留到进程退出，隐藏、换源、取消和错误关闭均等待排空；`imageRegionWorkers` 记录进程数。

| 预算 | 范围 |
| --- | --- |
| Gallery 会话 48MiB | 当前会话的基础层与细节 |
| 基础层最多 32MiB | 按物理采样直接解码；整层超限时先用不超过 4MiB 的粗层 |
| 共享输出 128MiB | 在途预留、保留图像及待绘制退役图像 |
| 通用 RegionContentSession 16MiB/4MiB | 默认会话/基础层，支持受控 tile 后端 |

基础层采样足够时省去细节，放大后合并可见矩形并补充 1:1 区域。`RegionImageSurface` 对基础与细节互斥裁剪，避免半透明像素重复混合。旧图先从显示状态移除，绘制后再释放根句柄；任务持独立来源租约。滤镜、颜色和源坐标保持稳定。

文件签名提前排除 GIF 等非 JPEG/PNG/WebP 来源，省去快照和 worker；候选格式中的动画、EXIF 方向和超容量视口明确回退。WebP 全局缩放中间层超过 40MiB 时也回退。已启动的区域工作先排空，再开始完整帧；损坏或进程异常保留错误状态并释放会话。

ImageSourceStore 目录由 CacheManager.imageSources 提供。普通完整帧不复制快照；最后来源/任务租约结束后删除快照。clear 保留活动文件，清理失活及遗留条目。诊断仅记录计数，避免明文路径和 URL。

## 验证边界

用例、命令及各阶段的像素、生命周期、能力回退和打包结果见[测试说明](../../../../test/common/widgets/image/CONTRACTS.md)。

2026-11-14 本机压力组各两轮对照，包含全部子进程的 Job 峰值保守降低 23.19%；可见延迟 p95 最差值从 791ms 增至 944ms（+153ms），未通过原定 10% 延迟门槛。测试矩阵已停止，真实混合组尚缺候选轮。最后增加的签名分流只做定向测试和分析，未重测性能；原始记录保存在本地 `doc/dev/`。

其他 GPU/驱动、Android、完整应用长期运行及通知原生缓存仍待设备验证。输出预算不包含全部解码工作区，完整帧回退仍可能产生大图峰值。跨 surface 区域去重、Android 原生区域后端和第二套通用像素 LRU 尚未实现；弹幕重复静态表情仍由各消费者各建 codec。

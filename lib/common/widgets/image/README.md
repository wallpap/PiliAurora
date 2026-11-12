# 图片模块

2026-11-13。目标与分阶段状态见[设计稿](../../../../doc/development/image-pipeline-design.md)，实现前路径清单见[调查快照](../../../../doc/development/image-usage-audit.md)。

## 入口与所有权

| 模块 | 入口与责任 |
| --- | --- |
| 完整帧 | `cached_image.dart` 保留 CachedImage、CachedImageProvider、LocalImageProvider、框架 decoder callback 和 Flutter ImageCache 协作。默认参数下原 Provider 相等性不变；外层 ResizeImage 仍可控制尺寸。 |
| 内容显示 | `content_image.dart` 管理订阅、加载/动画/可见需求、稳定源几何和显示帧；`image_viewer/content_viewer.dart` 对接 Viewer 手势视口。普通正文和预览仍使用完整帧。 |
| 共享资源 | `image_resources.dart` 在当前 binding 共享准入：默认两个原生任务、最多一个重预处理，owner 轮转、可见优先和等待老化。测试通过 runWith 注入隔离资源，不把 runtime 身份写入 Provider 键。 |
| 内部来源与采样 | `src/image_source_store.dart` 提供不可变快照租约；`src/image_sampling.dart` 按实际 decoder 元信息、BoxFit 和有效 DPR 推导足够的输出，尺寸向上归档。 |

`loadImageFrame(File)` 返回带 result/cancel/drained 的请求。result 为调用者独占的第 0 帧，使用结束必须 dispose；codec 在取帧后关闭。取消不会提前归还真实 native 名额，迟到图像由请求释放。`loadNetworkImageFrame` 先合并编码文件读取，再执行同一路径；isCurrent 在取得文件和实际准入后检查，供弹幕领域期限使用。

Provider 输出由 ImageStream/ImageInfo 管理，消费者只释放自己的 ImageInfo。ContentImage 更换帧后等当前绘制结束再释放旧引用；动画无监听和缓存交接规则仍由同一私有 completer 管理。加载许可可独立于动画：ImageLoadingScope 为 true、TickerMode 为 false 时仍可导出静态画面；Gallery 邻页继承父加载许可，只有当前页播放动画。正文仅在自身滚动时计算祖先有效裁剪交集，不增加全局逐帧头像扫描。

调用者提供的 sourceSize 是布局提示；实际 decoder 回报的原始尺寸优先。外层 ResizeImage 的已缩小帧不冒充原始元信息。卡片 cover 等目标用真实尺寸在现有 decoder callback 内计算，不增加预探测 codec；未知宽高比的 CDN 请求保留来源，代价是部分请求可能下载更多编码字节。

雪碧图保留原坐标与播放器 3 项/24MiB 缓存；弹幕保留期限、任务/字节配额和文本降级。普通图片表情保留动画并惰性建格；文字和混合历史保留 Wrap 的可变宽度行为。通知封面由现有音频插件单独设置 512×512 降采样，不占用 Dart 解码队列。

## 区域协议与门控

`src/region_content_session.dart` 的 productionRegionBackend 为 null，尚未接入 ContentImage 的区域选择。它只为真实后端准备可测契约：同版本源租约、有界基础层/细节、单层像素重叠、共享 64MiB 可控输出预算、任务取消及绘制退休排空。单会话默认 16MiB，基础层输出最多 4MiB；在途预留、保留图像和绘制待退役图像一起计费。RegionImageSurface 先发布移除旧图的状态，再于绘制后销毁根句柄；任务持独立租约，surface 退出和缓存清理不会删掉任务正在读的版本。

后端必须明确支持静态、独立区域和有界基础层；不满足时报告失败。完整解码再裁剪不属于可接受后端。受控后端测试验证协议和 ui.Image 引用，尚未覆盖跨 surface 同 tile 去重、真实格式工作区、EXIF、接缝和平台性能。当前超大图仍可能完整解码，不应据此宣称峰值已解决。

ImageSourceStore 的默认目录由 CacheManager.imageSources 提供。普通完整帧不复制快照；最后来源/任务租约结束才删除快照。clear 保护活动文件，清理失活及遗留条目；诊断输出仅低成本计数，不以明文路径或 URL 作为键。

## 验证边界

自动化命令和各契约见[测试说明](../../../../test/common/widgets/image/CONTRACTS.md)。真实 PNG 覆盖未知比例网络 cover、本地 cover、ResizeImage 元信息与失败后重试；受控帧覆盖关闭/取消、迟到来源、动画与稳定坐标；Widget 回归覆盖滚动裁剪、Viewer 手势、HTML CSS 标记与表情网格。

真实 Windows/Android 冷热缓存、帧耗时、进程/GPU 峰值、通知原生缓存和六类图像画质仍需设备对照。弹幕重复静态表情的一次性消费者各建 codec，只合并编码文件请求；重复解码性能待测，当前没有第二套通用像素 LRU。

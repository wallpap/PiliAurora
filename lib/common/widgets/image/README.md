# 图片模块

2026-11-14。目标与分阶段状态见[设计稿](../../../../doc/development/image-pipeline-design.md)，实现前路径清单见[调查快照](../../../../doc/development/image-usage-audit.md)。

## 入口与所有权

| 模块 | 入口与责任 |
| --- | --- |
| 完整帧 | `cached_image.dart` 保留 CachedImage、CachedImageProvider、LocalImageProvider、框架 decoder callback 和 Flutter ImageCache 协作。默认参数下原 Provider 相等性不变；外层 ResizeImage 仍可控制尺寸。 |
| 内容显示 | `content_image.dart` 管理订阅、加载/动画/可见需求、稳定源几何和显示帧；`image_viewer/content_viewer.dart` 对接 Viewer 手势视口。普通正文使用完整帧，Windows Gallery 可使用区域后端。 |
| 共享资源 | `image_resources.dart` 在当前 binding 共享准入：默认两个原生任务、最多一个重预处理，owner 轮转、可见优先和等待老化。测试通过 runWith 注入隔离资源，不把 runtime 身份写入 Provider 键。 |
| 内部来源与采样 | `src/image_source_store.dart` 提供不可变快照租约；`src/image_sampling.dart` 按实际 decoder 元信息、BoxFit 和有效 DPR 推导足够的输出，尺寸向上归档。 |

`loadImageFrame(File)` 返回带 result/cancel/drained 的请求。result 为调用者独占的第 0 帧，使用结束必须 dispose；codec 在取帧后关闭。取消不会提前归还真实 native 名额，迟到图像由请求释放。`loadNetworkImageFrame` 先合并编码文件读取，再执行同一路径；isCurrent 在取得文件和实际准入后检查，供弹幕领域期限使用。

Provider 输出由 ImageStream/ImageInfo 管理，消费者只释放自己的 ImageInfo。ContentImage 更换帧后等当前绘制结束再释放旧引用；动画无监听和缓存交接规则仍由同一私有 completer 管理。加载许可可独立于动画：ImageLoadingScope 为 true、TickerMode 为 false 时仍可导出静态画面；Gallery 邻页继承父加载许可，只有当前页播放动画。正文仅在自身滚动时计算祖先有效裁剪交集，不增加全局逐帧头像扫描。

调用者提供的 sourceSize 是布局提示；实际 decoder 回报的原始尺寸优先。外层 ResizeImage 的已缩小帧不冒充原始元信息。卡片 cover 等目标用真实尺寸在现有 decoder callback 内计算，不增加预探测 codec；未知宽高比的 CDN 请求保留来源，代价是部分请求可能下载更多编码字节。

雪碧图保留原坐标与播放器 3 项/24MiB 缓存；弹幕保留期限、任务/字节配额和文本降级。普通图片表情保留动画并惰性建格；文字和混合历史保留 Wrap 的可变宽度行为。通知封面由现有音频插件单独设置 512×512 降采样，不占用 Dart 解码队列。

## 区域协议与门控

Windows 的 `ContentImage` 在有交互视口、未指定缩小解码目标、来源为网络缓存或本地文件时选择随包的 `piliaurora_image_worker.exe`。当前用于 Gallery；普通正文、封面及其他平台继续完整帧路径。worker 不存在时保留完整帧兼容性。

`src/native_worker_backend.dart` 为每个不可变来源准备独立 CPU worker；系统 WIC 处理已验证的静态 JPEG/PNG，固定修复提交的 libwebp decoder 处理静态 WebP。二进制管道只返回有界预乘 RGBA，交给普通 `ui.Image`；不使用外部 GPU 纹理或 raw 临时文件。来源租约持续到 worker 退出，隐藏、替换、取消和错误关闭均排空。诊断 `imageRegionWorkers` 提供当前进程数。

Gallery 会话最多 48MiB，基础层按当前物理采样直接解码，整层可容纳时最多 32MiB；否则先准备不超过 4MiB 的粗层，再请求合并后的可见矩形。共享输出预算 128MiB，涵盖在途预留、保留图像与待绘制退休图像。基础层足够时不重复解码细节；放大时补 1:1 区域。`RegionContentSession` 通用协议仍支持受控 tile 后端，默认会话 16MiB、基础层 4MiB。

`RegionImageSurface` 对基础层和细节使用互斥裁剪，防止半透明像素重复 source-over。先发布移除旧图的状态，再在绘制后释放根句柄；任务持独立来源租约。滤镜和颜色参数沿用 ContentImage，换采样层不改变来源坐标和 Viewer 手势。

来源先读取文件签名，GIF 等非 JPEG/PNG/WebP 格式直接走完整帧，省去快照复制和 worker 启动；候选格式的动画、EXIF 方向及超过已验证容量的视口由区域后端识别并回退。WebP 保持全局缩放相位所需的中间层超过 40MiB 时同样回退。已启动的区域进程退出后才启动完整帧。解码损坏或进程错误显示错误并释放会话，不暗中完整解码。输出预算不约束任意格式的内部解码工作区，完整帧回退仍可能产生大图峰值。尚无跨 surface 同区域去重，也未启用 Android 原生区域实现。

ImageSourceStore 的默认目录由 CacheManager.imageSources 提供。普通完整帧不复制快照；最后来源/任务租约结束才删除快照。clear 保护活动文件，清理失活及遗留条目；诊断输出仅低成本计数，不以明文路径或 URL 作为键。

## 验证边界

自动化命令和各契约见[测试说明](../../../../test/common/widgets/image/CONTRACTS.md)。真实 PNG 覆盖未知比例网络 cover、本地 cover、ResizeImage 元信息与失败后重试；受控帧覆盖关闭/取消、迟到来源、动画与稳定坐标；Widget 回归覆盖滚动裁剪、Viewer 手势、HTML CSS 标记与表情网格。

Windows 原生像素、裁剪、取消、隐藏重开、能力回退与打包回归入口见[测试契约](../../../../test/common/widgets/image/CONTRACTS.md)。本机 Gallery 对照包括冷/热打开、缩放拖动、快速翻页及退出后 90 秒；设备证据留在本地 `doc/dev/`。其他 GPU/驱动、Android、完整应用长期运行、通知原生缓存仍需设备验证。弹幕重复静态表情的一次性消费者各建 codec，只合并编码文件请求；当前没有第二套通用像素 LRU。

2026-11-14 本机压力组各两轮对照，包含全部子进程的 Job 峰值保守降低 23.19%；可见延迟 p95 最差值由 791ms 增至 944ms（增加 153ms），未通过原定 10% 延迟门槛。按用户接受适量延迟、减少重复验证的要求结束矩阵，真实混合组尚缺候选轮。随后增加的文件签名提前分流仅完成定向测试与分析，未重测性能；该收益不作为最终代码或其他设备的保证。

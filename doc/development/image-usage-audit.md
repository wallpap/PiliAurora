# 图片使用场景与解码路径调查

调查日期：2026-11-12。本文是重构实施前的源码快照，保留原始调用计数；2026-11-13 的实施状态见[图片加载与预览设计稿](image-pipeline-design.md)。调查范围为当时工作区源码、固定 Flutter 3.47.5、应用使用的本地图片相关依赖及 Android/Windows 自有原生入口。发现绕行路径或大资源保留的可能性，不等于已经证实该路径发生内存泄漏。

## 方法与覆盖范围

先按调用表达式扫描，再沿来源、显示、缓存、动画及释放关系人工归类。AST 扫描包括 `lib/`、`third_party/flutter_html/lib/`、`third_party/cached_network_image_ce/lib/`、`third_party/canvas_danmaku/lib/`；另外检索自有平台代码并追踪 `audio_service` 的实际封面加载。

- 解析 1,448 个 Dart 文件，排除 103 个 protobuf 等生成文件，解析诊断文件为 0。
- 记录 356 项候选调用，其中应用 328 项，分布于 160 个文件；三个依赖分别为 4、14、10 项。
- 主要入口为 `NetworkImgLayer` 154 处、`CachedImage` 21 处、`CachedImageProvider` 7 处、`PendantAvatar` 13 处、`ImageGridView` 5 处、`PageUtils.imageView` 15 处、表情 tooltip 8 处。
- 其他入口包括 `Image.asset` 37 处、`Image.file` 4 处、`Image.memory` 1 处、`RawImage` 3 处、`DecorationImage` 3 处、`SvgPicture.asset` 5 处、网络 SVG 1 处、原生裁剪调用 3 处、二维码 2 处。

这是语法调用清单，包含基础设施内部调用及一处 Provider 淘汰键构造，不是运行时 decoder 数量或互斥业务分类。查看器自定义类也叫 `Image`，须按 import 区分；依赖支持某种构造不代表应用当前使用它。补充检索覆盖直接 codec、图像 buffer、生成栅格、原生 BitmapFactory 和委托给插件的图片，避免只数 Widget。

本次本地扫描工具及 JSON 留在 `build/image-usage-audit/`，可在当前工作区运行 `fvm dart run build/image-usage-audit/audit_image_usage.dart` 更新；它们是调查产物，不是应用构建依赖。

## 1. 封面、头像与装饰

| 子场景 | 当前调用关系及源码 | 必须保留的语义 |
| --- | --- | --- |
| 视频、番剧、音频、直播、收藏、搜索、历史等卡片 | 页面 → [NetworkImgLayer](../../lib/common/widgets/image/network_img_layer.dart) → `CachedImage` → `CachedImageProvider` | 布局、裁剪与对齐、CDN 变体、占位和有效 DPR |
| 头像、认证与头像挂件 | 页面 → [PendantAvatar](../../lib/common/widgets/pendant_avatar.dart)；头像和挂件分别调用 `NetworkImgLayer` | 挂件透明边界、超出头像的绘制尺寸、来源可能带动画 |
| 用户空间头图、装扮、活动标识 | [用户信息卡](../../lib/pages/member/widget/user_info_card.dart)、[动态作者](../../lib/pages/dynamics/widgets/author_panel.dart)、搜索等直接使用 `CachedImage` | 有些宽度由父布局确定，不能只根据组件名称推断解码尺寸 |
| 下载和本地视频封面 | [下载条目](../../lib/pages/download/detail/widgets/item.dart)、[本地视频简介](../../lib/pages/video/introduction/local/view.dart) → Flutter `Image.file` | 有显示宽高，但没有相应解码尺寸参数；目前未走网络图片的准入路径 |

[ImageType](../../lib/models/common/image_type.dart) 目前只有 `avatar/emote/def`，主要控制外观。挂件也使用 `.emote`，所以不能把此枚举直接升级成解码策略或据此统计普通表情数量。

`NetworkImgLayer` 选择一个目标解码维度，使用有效 DPR 和 CDN helper，设置约 1MP 输出面积上限；`CachedImage` 也默认此上限。原始 `CachedImageProvider` 默认不设面积上限。显示尺寸、目标解码尺寸、原生峰值是三个不同量。

## 2. 正文图片与 GIF

| 子场景 | 当前调用关系及源码 | 调查结论 |
| --- | --- | --- |
| 专栏 HTML 正文 | [htmlRender](../../lib/pages/article/widgets/html_render.dart) 的 `img` TagExtension → `CachedImage`；点击 → 图片查看器 | 普通正文按文章宽度显示，表情按 22 逻辑像素显示；部分分隔/截断图片单独处理 |
| 专栏结构化正文 | [opusContent](../../lib/pages/article/widgets/opus_content.dart) → 单图 `CachedImage` / 多图 `ImageGridView` | 单图可按比例展示完整长图，不限于一个屏幕；正文阅读需要当前可见段的文字细节 |
| 动态、转发与评论附件 | [动态正文](../../lib/pages/dynamics/widgets/content_panel.dart)、[富节点](../../lib/pages/dynamics/widgets/rich_node_panel.dart)、[转发列表](../../lib/pages/common/dyn/repost_list/widgets/item.dart)、[评论](../../lib/pages/video/reply/widgets/reply_item_grpc.dart) → [ImageGridView](../../lib/common/widgets/image_grid/image_grid_view.dart) | 网格使用裁剪缩略显示，点击后另行预览；长图标识、顶部对齐和 Live Photo 菜单有各自语义 |
| 私信图片与卡片 | [ChatItem](../../lib/pages/whisper_detail/widget/chat_item.dart) → `NetworkImgLayer` / `CachedImage` | 图片消息宽度至多 220，按原比例计算完整高度，没有同等高度上限；不能全部视为小面积缩略图 |
| 编辑、待发送附件 | [发布编辑页](../../lib/pages/common/publish/common_rich_text_pub_page.dart) → 本地 `Image.file` 或网络 `CachedImage`；点击 → 图片查看器 | 本地显示缺少目标解码尺寸；显示优化不得改写上传原文件 |
| 背景和装饰 Provider | [屏蔽卡片](../../lib/pages/article/widgets/opus_content.dart) 使用 `ResizeImage(CachedImageProvider)`；[SuperChat](../../lib/pages/live_room/superchat/superchat_card.dart) 使用直接 Provider | 前者已有宽度约束；后者不能继承 `CachedImage` Widget 的默认面积上限，须核对实际背景和目标尺寸 |

GIF/动画 WebP 通过完整帧 completer 播放，不应按“正文”“头像”或扩展名一概静态化。当前解码队列不仅约束首帧，后续动画 `getNextFrame()` 也重新取得准入名额。

正文长图是第二版设计遗漏的核心场景：若按页面宽度可读地展示完整高度，总像素需求仍可能远超固定 1MP。区域显示能力必须同时服务正文滚动和点击预览；为裁剪网格全面引入瓦片则没有同等收益。

HTML 还有一个依赖内的潜在绕行入口：[CSS 列表标记图片](../../third_party/flutter_html/lib/src/css_box_widget.dart) 使用 `Image.network`，不经过 `img` 扩展。内置 `image_builtin.dart` 虽支持网络/base64/asset，但当前应用 `img` 已被自定义扩展接管，不能据包内代码认定这些分支都在实际运行。CSS 来源是否出现在设备内容中尚未复现。

## 3. 普通表情与弹幕表情

### 普通表情

| 入口 | 当前实现 | 生命周期关注点 |
| --- | --- | --- |
| 评论、动态、专栏富文本 | [评论表情](../../lib/pages/video/reply/widgets/reply_item_grpc.dart)、[动态富节点](../../lib/pages/dynamics/widgets/rich_node_panel.dart)、[专栏富节点](../../lib/pages/article/widgets/opus_content.dart) → `WidgetSpan` + `NetworkImgLayer` + tooltip | 保持行内尺寸、动画来源、点击/悬浮放大与透明边界；评论来源优先选择 webp/gif URL |
| 私信、输入编辑器 | [私信](../../lib/pages/whisper_detail/widget/chat_item.dart)、[文本控制器](../../lib/common/widgets/flutter/text_field/controller.dart) | 编辑器约 22×22；不能把 WidgetSpan 的保留时间当作正在屏幕内显示 |
| 普通表情选择面板 | [EmotePanel](../../lib/pages/emote/view.dart) | `SingleChildScrollView → Wrap → map(...).toList()` 同时建立全部条目；图片表情可在不可见行持续保有订阅。文字表情是 `Text`，不属于图像解码 |
| 表情包预览/管理 | [EmotePreview](../../lib/pages/emote/preview.dart) | `GridView.builder`，放大走独立 dialog，未统一经过 GalleryViewer |
| 直播聊天列表与表情选择 | [ChatPanel](../../lib/pages/live_room/widgets/chat_panel.dart)、[LiveEmotePanel](../../lib/pages/live_emote/view.dart) | 聊天 `WidgetSpan` 属普通 UI 图片；直播表情选择已使用 `GridView.builder`，不能与普通面板的 eager Wrap 混为一谈 |
| Tooltip | [emoteTooltipBuilder](../../lib/common/widgets/emote_tooltip.dart) | OverlayPortal 按展示需求建立放大图，退出浮层必须归还独立订阅 |

普通表情需要保留动画；改进重点是按可见范围建立需求、按需放大和离屏暂停。仅看页面 `TickerMode` 不足以判断活动滚动列表中的某个表情是否离屏。

### 弹幕表情与弹幕栅格

[LiveDanmakuLayer](../../lib/pages/danmaku/live_layer.dart) 目前通过 `CachedImageProvider(maxDecodePixels: 1 << 16)` 取一次 `ImageInfo`，克隆图像并移除 listener，不持续订阅动画。命中共享动画流时，首次收到的图像也可能是流的当前帧，不能把现状表述为严格读取文件第 0 帧。

[LiveDanmakuQueue](../../lib/pages/danmaku/live_queue.dart) 另有业务准入：候选上限 120、资源任务上限 4、资源等待 300ms、最大年龄 1s、资源预算 2MiB、单候选图片上限 256KiB。这些截止时间和淘汰规则属于弹幕语义。一般图片调度不能替它们决定弹幕是否过期。

[DanmakuRasterCache](../../lib/pages/danmaku/raster_cache.dart) 及 [canvas_danmaku/TextRenderer](../../third_party/canvas_danmaku/lib/text_renderer.dart) 把文字和已解码表情绘制成新的 `ui.Image`；`recordDanmakuImage/rasterizeSpecial` 使用 `Picture.toImageSync`。这属于生成栅格，必须与远程表情文件的解码分别记账和释放。直播聊天数据名中出现 Danmaku，不意味着聊天 Widget 属于弹幕覆盖渲染器。

## 4. 点击预览

主要入口为 `PageUtils.imageView → GalleryViewer → 自定义 Image → Viewer`，覆盖正文/评论网格、私信、用户头像/头图、音频封面、投票图片和编辑附件等。[GalleryViewer](../../lib/common/widgets/image_viewer/gallery_viewer.dart) 包括本地、网络与 Live Photo 分支。

- 网络分支直接使用 `CachedImageProvider`，原图没有 `CachedImage` Widget 的默认 1MP 限制；加载中可使用另一个低质量 URL 与 ResizeImage 占位。
- 本地分支使用自定义 `Image.file`，最终为 Flutter `FileImage`，目前未纳入网络帧准入。
- 实施前的自定义 Image 按解码尺寸形成内容尺寸；Viewer 对尺寸变化会调整/重置手势。该旧文件已移除，当前由 [ContentViewer](../../lib/common/widgets/image_viewer/content_viewer.dart) 和 [ContentImage](../../lib/common/widgets/image/content_image.dart) 提供稳定源几何；本条保留原问题的调查结论。
- 表情包放大 dialog 属独立预览路径；所有放大入口均需纳入验收，不以 GalleryViewer 一处代表全部。
- Live Photo 视频播放、原图下载/分享、上传文件与本地原件具有各自语义。显示所用像素、瓦片或 CDN 缩略图不能替代保存原件。

## 5. 其他场景与独立资源域

| 场景 | 源码与现状 | 设计归属 |
| --- | --- | --- |
| 播放进度雪碧图 | [VideoShotImage](../../lib/plugin/pl_player/view/widgets.dart) 直接 `instantiateImageCodecFromBuffer` 取图；[PreviewImageCache](../../lib/plugin/pl_player/utils/preview_image_cache.dart) 每播放器 3 项/24MiB，合并在途、显示 clone、代次保护 | 将一次性解码纳入共享准入；保留按源坐标裁剪及已有领域缓存，不能任意套 CDN 缩放。文件名式磁盘键的身份冲突需另测，尚非已证实泄漏 |
| SVG 公式、矢量资源 | [CachedNetworkSVGImage](../../lib/common/widgets/image/cached_network_svg_image.dart) → 文本读取 → `SvgPicture.string`；公式显式以 latex 作为 cacheKey | 保留 flutter_svg 解析/渲染语义，不进入位图瓦片 decoder；只复用适用的来源、错误与活动控制 |
| 内置图片及动画 | `Image.asset`，以及[投币动画](../../lib/pages/video/pay_coins/view.dart) `Image.memory` | 保留 Flutter 帧生命周期和首帧回调/付款计时关系；不对小型内置资产强制创建网络快照 |
| 截图、分享卡片、二维码 | [Screenshot](../../lib/utils/screenshot.dart)、保存面板、SuperChat 截图与 `PrettyQrView` | 属生成/导出任务，产物由调用者拥有；截图树明确允许加载图片而关闭 TickerMode，两个权限不能合并 |
| 视频输出交接截图 | [VideoOutputHandoff](../../lib/plugin/pl_player/utils/video_output_handoff.dart) | 原生输出重配期间保持画面，按播放器确认时机释放；不能作为普通空闲图片淘汰 |
| Android 媒体通知封面 | [AudioHandler](../../lib/services/audio_handler.dart) → `MediaItem.artUri` → [audio_service](../../third_party/audio_service/lib/audio_service.dart) 磁盘文件 → [AudioService.java](../../third_party/audio_service/android/src/main/java/com/ryanheise/audioservice/AudioService.java) BitmapFactory | 当前应用未设置 artDownscaleWidth/Height；插件无降采样分支可完整解码，并持有按 Java 最大堆 1/8 配置的 Bitmap LRU。该路径独立于 Dart ImageCache，须独立定尺寸、核对宿主引用和观测；不能用 Dart 预算覆盖它 |
| Android 固定快捷方式图标 | [AndroidHelper.createShortcut](../../android/app/src/main/java/io/github/wallpap/piliaurora/AndroidHelper.java) BitmapFactory.decodeFile | 一次性系统集成任务，不是常规图片 Widget 路径；输入尺寸和原生生命周期单独处理 |
| 原生裁剪、WebView、视频纹理 | 裁剪插件调用、页面 WebView、media_kit 输出 | 由插件/原生域处理；返回文件的显示可接统一帧加载，内部内存不纳入 Dart 可控工作集承诺 |

应用没有直接实例化 `cached_network_image_ce` 的 `CachedNetworkImage/Provider`；它提供缓存管理接口及被依赖包使用的实现，不能仅凭依赖源码推断应用还有一套活跃的通用 Widget 图片管线。自有应用没有发现 `package:image` 的像素解码调用。

原生调查核实了上述 Android 路径及自有平台代码，未对所有外部插件、OS 图像引用或 GPU 后端做穷尽证明；Windows/Android 设备上实际贡献须分项测量。

## 影响设计的决定

1. 场景是显示需求，不按五类建立五套 decoder；来源身份、原生准入与迟到结果释放集中维护。
2. 区域显示同时覆盖正文长图和交互预览；只扩展 GalleryViewer 会漏掉点击前的阅读问题。
3. 普通表情保持动画、改造 eager 图片网格与可见性；弹幕采用独立的单帧消费契约，保留业务截止时间。
4. Widget、直接 Provider、装饰、本地文件、HTML 依赖和一次性 codec 都要纳入迁移清单。
5. 只保留一个通用 Flutter 帧 LRU，但允许雪碧图、弹幕栅格等有明确语义与所有者的领域缓存；“只有一个完整帧缓存”不符合当前源码。
6. 加载许可、动画许可与可见性分开；截图是加载开启、动画关闭的实际反例。共享使用者的需求取聚合，单方退出不得关闭其他消费者。
7. 原生封面、生成栅格、视频纹理单独归属，不能把一个 Dart 解码队列称为整个进程的图片内存控制器。

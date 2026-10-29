# 播放、弹幕与消息设置

设置的生效范围与对应入口如下。媒体加载由 `PlaybackSession` 管理，播放器实例会跨视频页面复用，因此设置生效范围应以会话和媒体加载为准。

| 设置 | 行为与生效时机 | 主要入口 |
| --- | --- | --- |
| 手动播放前预加载视频 | 关闭自动播放时提前加载并暂停在续播位置；关闭后解析来源并等待点击。每次查询完成时读取当前设置 | `pages/video/controller.dart`、`playback_session.dart` |
| 自动播放、自动全屏、自动退出全屏 | 页面和播放动作读取最新偏好；预加载保持暂停意图 | `pages/video/view.dart`、`pl_player/controller.dart` |
| 后台播放、点播弹幕开关 | 设置页同时更新当前播放器状态 | `setting/models/play_settings.dart` |
| 不保存播放器内的临时调整 | 播放器中的播放顺序、画中画、后台播放等调整继续在当前会话生效，开启时不写入默认偏好；弹幕和字幕独立保存 | `pl_player/controller.dart` |
| 缓冲大小、缓冲时长 | 下一次媒体加载生效；点播前后向各受大小上限约束，独立音视频分别缓冲。时长按倍速转换，直播使用独立策略 | `storage_pref.dart`、`capturePlaybackConfiguration` |
| 视频同步、音频时钟平滑 | 捕获到媒体计划，下一次媒体加载生效 | `capturePlaybackConfiguration` |
| Android 音频输出后端 | 选择 OpenSL ES、AAudio、AudioTrack 的尝试顺序；重新创建播放器时生效 | `PlaybackRuntimeConfig` |
| Android 纹理缩放 | 输出尺寸策略读取当前设置，随后准备媒体输出时应用 | `native_playback_runtime.dart` |
| 超分辨率 | 默认档位用于番剧，其他视频可在播放器选择；根据源视频和屏幕分辨率判断可用性 | `super_resolution_policy.dart`、`setShader` |
| 弹幕帧率 | Android 等平台支持目标档位，Windows 跟随屏幕；当前弹幕立即更新且保留显示实例 | `frame_rate_setting.dart`、`frame_scheduler.dart` |
| 弹幕密度、固定速度、固定转滚动、轨道间距 | 作用于窗口编排与呈现几何；配置交接保留活动弹幕资源 | `window_renderer.dart`、`arrangement.dart` |
| 会员彩色弹幕、合并及合并字号 | 当前来源刷新规则与显示内容；不重新获取播放器 | `pages/danmaku/view.dart` |
| 禁用“收到的赞”入口和角标 | 消息页入口禁用，首页未读数排除赞；已有订阅立即更新 | `messaging/preferences.dart` |
| 消息未读类型、未读标记样式 | 控制首页消息角标的汇总分类与表现 | `home/view.dart`、`UnreadSnapshot.total` |
| 消息接收、关键词屏蔽、联系人设置 | 服务端账号设置，按账号 Session 读写；和本地入口偏好分别管理 | `messaging/settings.dart` |

旧 `enableAndroidVideoOutputSize` 已没有运行路径，定义已移除。Android 输出统一经过当前尺寸策略，纹理缩放仍有独立开关。Windows 设置中不再出现 Android 音频后端选择；旧保存值保留在本地设置中，不参与运行。

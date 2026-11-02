# 播放器与弹幕架构图

以下图表对应当前源码中的播放器会话、弹幕显示和帧呈现调度。HTML 文件自带 SVG 与样式，可直接在浏览器查看。

- [播放器架构](player-architecture.html)：页面所有权、会话状态、原生运行时、媒体实例、输出交接与平台输出。
- [弹幕架构](danmaku-architecture.html)：点播范围窗口、直播候选队列，以及共用的渲染和帧调度。
- [调度引擎架构](presentation-scheduler-architecture.html)：构建身份、视频采样准入和 Android／Windows 帧调度路径。
- [跨模块交互时序](playback-danmaku-sequence.html)：加载至帧显示的协作，以及暂停、跳转或输出变化时的失效处理。

图中 `standard`、`androidFramePlan`、`windowsDwmPaced` 是项目呈现配置名称；自编引擎由构建身份校验，实际设备呈现效果仍以目标平台探针为准。

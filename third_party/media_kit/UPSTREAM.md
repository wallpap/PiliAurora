# media_kit 本地版本

- 本地版本：`1.1.11+piliaurora.6`；来源包版本：`1.1.11`。
- 来源仓库：https://github.com/My-Responsitories/media-kit.git
- 来源提交：`73771ec38176be2d984a3049c28177bce23b54a0`。
- 来源子目录：`media_kit`。
- 许可证：LICENSE。
- 保留原因：保留 native 播放器、直接 FFI 调用与 libmpv 生命周期实现。

仅收录生产源码、构建配置、资源及许可说明；不复制上游示例、测试、缓存或 Git 元数据。
导入时除包版本、禁止发布声明及必要依赖声明外，不重写来源实现。
这些包不是 pub.dev 同名版本的镜像，不可仅修改根版本号宣称已升级。
更新流程见 `../README.md`，来源登记见 `../dependencies.json`。

2026-10-09：增加基于原生事件的字符串属性观察；同步和异步控制请求向调用方传递失败并保留错误流，异常路径释放参数内存。播放器创建传播初始化失败并回收句柄，`osc` 在初始化前按选项设置。seek 排队执行时核对媒体身份。

2026-10-10：Android 带独立音轨的媒体使用 `absolute+exact` 跳转，避免视频落到较早关键帧后等待请求位置的音轨；同文件播放保留关键帧跳转。识别当前媒体的 `audio-files-append` / `audio-files`，以及通过 `AudioTrack.uri` 选中的外部音轨。

2026-10-16：以单一 native event reader 复制 start/file-loaded/end-file、track-list 变化与队列溢出事实；仅在读到 NONE 后发出批次 drain 确认。生命周期 hook 使用受限同步 API，追踪借用及 continue-once，带取消/截止时间竞争。播放器释放等待 hook、输出、reader 退出后在 worker isolate 执行 mpv destroy，并公开真实 released 回执；FILE_LOADED 同批次提供可空的轨道、音频和 seekability 快照。后续 video-out-params 变化复制为带当前文件身份的事件，供暂停加载等待实际输出几何。

2026-10-19：seek 可携带观察序号；单一事件 reader 以命令请求回执、SEEK 与同文件 PLAYBACK_RESTART 关联完成。新文件、退出和事件队列溢出清除旧关联，在途记录阻止重复 seek 覆盖。原生提交回执与落点完成分别通知调用方。

2026-10-21：公开句柄所用的 nativeLibraryPath，供媒体时钟在 worker isolate 读取属性时复用实际加载的库路径，包含调用方指定路径。

2026-10-27：open 在 libmpv 接受 loadfile 后同步通知调用方，并等待加载命令回执。运行时据此区分提交前失败和提交后回执迟到，按实际原生归属执行卸载与关闭。

2026-10-30：单一 native reader 将 `eof-reached` 复制为带当前文件身份、位置及媒体时长的 `NativePlaybackEof`，覆盖 keep-open 保留文件时的播放结束和 seek 后恢复；文件卸载继续沿用独立的 end-file 事实。

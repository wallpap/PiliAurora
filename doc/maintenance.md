# 维护与排障

## 开始修改前

1. 阅读根目录的 `AGENTS.md` 和 [文档索引](README.md)。
2. 执行 `git status --short` 和 `git diff`，了解并保留工作区已有改动。
3. 从路由或页面入口沿实际调用关系阅读：页面 → HTTP/Service → Model → 通用组件或平台插件。
4. 查看相关测试和诊断入口，确定本次修改范围。
5. 修改后运行相关测试与静态分析。播放器、直播、窗口和解码器改动还要说明实测覆盖的平台。

## 常见调用链

### 播放

`lib/pages/video/` → `lib/http/video.dart` 和视频模型 → `lib/plugin/pl_player/` → `media_kit` 与平台库。排查时区分地址解析、网络、解码、渲染和窗口阶段。播放器诊断入口在 `lib/services/diagnostics/player_diagnostics.dart`。

### 视频弹幕

视频详情或播放器 → 弹幕 API 与解析 → 弹幕状态和渲染。Windows 高密度场景请记录编码、分辨率、输出尺寸、弹幕密度、硬件解码状态、构建模式和复现时长。

### 直播

`lib/pages/live_room/` → `lib/http/live.dart` 与 `lib/services/live_stream/` → 直播包解码 → 消息和弹幕 UI。连接、包解码、历史与未读消息、渲染和退出清理需要分别检查。

### 下载

`lib/pages/download/` → `lib/services/download/` → `lib/http/download.dart`、响应适配和流式写入 → 本地下载目录。重点检查路径权限、磁盘空间、网络重试、写入回压和任务生命周期。

### 登录与账号

`lib/pages/login/` → `lib/http/login.dart` → `lib/services/account_service.dart`、`lib/utils/accounts/` 与本地存储。日志和 issue 内容应去掉 Cookie、Token、二维码和签名信息。

## 诊断入口

- `lib/services/diagnostics/`：播放器、HTTP、进程指标、历史读取、记录保存和脱敏。
- `lib/services/logger.dart`：日志服务。
- `lib/pages/setting/pages/logs.dart` 和 `lib/pages/log_table/`：设置中的日志界面。
- [构建与测试](build-and-test.md)：本地验证方式和平台限制。

## 问题报告

请提供应用版本、Git 提交、构建模式和目标平台；操作系统、设备或显卡及 Flutter/JDK 版本；复现步骤、媒体编码与分辨率、弹幕密度和复现频率；登录、硬件解码和网络状态；脱敏后的诊断摘要及时间范围。明确标出尚未验证的假设。

## 复现和测量

- 对照测量使用固定媒体片段、构建模式、显示器/DPI、弹幕密度和解码后端。分别启动进程并重复采样；累计计数使用同一测量窗口的差值，初始画面无效的样本不计入结果。
- 分别记录 Flutter Build/Raster 帧时间、mpv 丢帧、进程内存和 GPU 显存。用 `hwdec-current` 确认解码后端；零拷贝和最终显示效果需要单独验证。输出尺寸限幅会改变渲染表面，源视频仍按原分辨率解码。
- 弹幕优化要同时检查接受数量、普通与高级弹幕的像素和透明度、慢帧及内存。预热会提前承担栅格化开销；缓存淘汰后仍可能被活动图片引用，因此也要观察活动工作集、字节上限和条目上限。
- Android 解码恢复要结合媒体生命周期、暂停、缓冲、seek、EOF、持续错误和实际出帧判断。单次取图错误或播放位置推进都不足以证明画面恢复。旋转验收覆盖播放中、暂停、恢复播放和切源。
- 独立音轨和视频使用同一绝对 seek 目标。Windows 空音视频输出烟测检查命令和时序；实际音频及 Android MediaCodec 仍需分别验收。
- 直播历史与滚动期间的新消息积压分别限界，并检查恢复跟随、略过计数和退出清理。WebView 与原生播放器销毁前应等待异步任务退出，再检查退出、重建和多引擎场景。

本地实验记录放在 Git 忽略的 `doc/dev/`，临时输出放在 `build/`。保留复现条件和结论，清理失效样本、重复二进制和日志。历史设备数值应重新测量后再用于当前决策。

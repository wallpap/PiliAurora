# 维护与排障手册

## 修改前

1. 阅读根目录约定和 `doc/README.md`。
2. 执行 `git status --short`、`git diff`，确认并保留已有改动。
3. 从路由或页面入口沿实际 import 阅读：页面 → HTTP/Service → Model → 通用组件/平台插件。
4. 先看相关领域的测试和诊断入口，再确定修改范围。
5. 修改后运行相关测试和静态分析；播放器、直播、窗口、解码器改动还需要说明实测范围。

## 典型链路

### 播放

`lib/pages/video/` → `lib/http/video.dart`/视频模型 → `lib/plugin/pl_player/` → `media_kit` 和平台库。遇到问题时区分地址解析、网络、解码、渲染和窗口阶段；播放器诊断入口是 `lib/services/diagnostics/player_diagnostics.dart`。

### 视频弹幕

视频详情/播放器 → 弹幕 API 与解析 → 弹幕状态/渲染。Windows 高密度场景应同时记录编码、分辨率、输出尺寸、弹幕密度、硬件解码状态、构建模式和复现时长。

### 直播

`lib/pages/live_room/` → `lib/http/live.dart` 与 `lib/services/live_stream/` → 直播包解码 → 消息/弹幕 UI。分别排查连接、包解码、历史/未读、渲染和退出清理。

### 下载

`lib/pages/download/` → `lib/services/download/` → `lib/http/download.dart`、响应适配和流式写入 → 本地下载目录。检查权限、磁盘空间、网络重试、回压和任务生命周期。

### 登录与账号

`lib/pages/login/` → `lib/http/login.dart` → `lib/services/account_service.dart`、`lib/utils/accounts/` 和本地存储。日志和 issue 需要先脱敏，去掉 Cookie、Token、二维码和签名信息。

## 诊断入口

- `lib/services/diagnostics/`：播放器、HTTP、进程指标、历史读取、记录保存和脱敏。
- `lib/services/logger.dart`：日志服务。
- `lib/pages/setting/pages/logs.dart`、`lib/pages/log_table/`：设置/日志相关 UI。
- `doc/build-and-test.md`：项目构建和验证方式。

## 提交问题报告时

- 应用版本、Git 提交、构建模式和目标平台；
- 操作系统、设备/显卡、Flutter/JDK 版本；
- 复现步骤、媒体编码/分辨率/清晰度、弹幕密度和复现频率；
- 登录状态、硬件解码状态、网络条件；
- 脱敏后的诊断摘要、时间范围和已排除项；
- 仍未验证的假设。

## 可复用的排障经验

- 对照测量固定媒体片段、构建模式、显示器/DPI、弹幕密度和解码后端，分别启动进程并重复采样。累计计数采用同一测量窗口的差值；初始画面无效的样本先排除。
- Flutter Build/Raster 帧时间、mpv 丢帧、进程内存和 GPU 显存分别记录。`hwdec-current` 用于确认后端，零拷贝及最终显示效果需要额外证据；输出尺寸限幅改变渲染表面，源视频仍按原分辨率解码。
- 弹幕优化同时检查接受数量、普通/高级弹幕的像素与透明度、慢帧和内存。预热会转移栅格化开销；缓存淘汰后仍可能存在活动图片引用，应同时观察活动工作集、字节上限和条目上限。
- Android 解码恢复结合媒体生命周期、暂停、缓冲、seek、EOF、持续错误和实际出帧判断。单条取图错误或播放位置推进不足以判定画面；旋转验收覆盖播放中、暂停后、恢复播放和切源。
- 独立音轨 seek 与视频使用同一绝对目标；Windows 空音视频输出烟测验证命令与时序，实际音频和 Android MediaCodec 另行验收。
- 直播历史与滚动期间的新消息积压分别限界，检查恢复跟随、略过计数和退出清理。WebView 与原生播放器销毁前等待异步任务退出，分别验证退出、重建和多引擎场景。

本地实验摘要与数据放在受 Git 忽略的 `doc/dev/`，临时输出放在 `build/`。保留复现所需的输入条件和结论，定期清理失效样本、重复二进制和日志。历史设备数值需要重新测量后再用于当前决策。

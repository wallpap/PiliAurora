# 原生播放链路与性能验证

日期：2026-10-06。分支：`refactor/native-playback-direct`。

## 目标与边界

优先降低 CPU 开销、内存占用及快速切源时的资源峰值，不为“直通”形式另建原生窗口。
继续使用已锁定的 media_kit/libmpv，不新增、升级生产依赖，不修改 Pub 缓存或用户保存的配置。

本次直通包含：

1. **媒体直载**：DASH 的视频 URL 直接作为 mpv 主媒体，音频通过 file-local
   `audio-files-append` 加载，不再构造两路 EDL；仅音频模式直接加载独立音频。
2. **解码直通优先**：Windows 默认从 `auto-copy` 改为 `d3d11va,auto`，最终保留软件回退。
   已保存的 `auto-copy`、指定后端顺序、关闭硬解等显式选择不改写。
3. **单路生命周期**：加载任务串行执行，尚未开始的过期请求跳过，运行中请求在异步返回后
   检查代次。复用已初始化的播放器，播放器最终销毁使旧加载失效，晚到的初始化资源被释放。
   重连也经过加载队列，且同一媒体只保留一个待执行重连定时器。

**不等于整条图形链零拷贝**：现有 Windows 输出仍经过 mpv OpenGL render API、
ANGLE/D3D11、Flutter 共享纹理及弹幕/控件合成。依赖的 `ANGLESurfaceManager::Read`
仍有 GPU 内 `CopyResource`，本次没有移除它，也没有改为 `gpu-next` 原生窗口。
Android 渲染及硬解默认策略不变。

旧式多段 durl 的 EDL 拼接不属于本次 DASH 音视频合流改动，仍保留。

## 代码入口

- `lib/plugin/pl_player/utils/native_media_source.dart`：直载媒体构造与音轨参数转义。
- `lib/plugin/pl_player/utils/playback_load_queue.dart`：互斥、latest-wins、失效及错误隔离。
- `lib/plugin/pl_player/controller.dart`：资源创建、切源、刷新与销毁的接入点。
- `lib/plugin/pl_player/models/hwdec_type.dart`：平台默认硬解顺序。

`media_kit` 当前锁定版本将 `Media.extras` 拼接为 `loadfile` 的逗号分隔选项字符串。
因此音频路径先用 `%<UTF-8 字节数>%` 包装；`audio-files-append` 只接收单个原样路径，
避免 Windows 分号或 Unix 冒号被再次解释为路径列表。刷新时保留同一媒体的 extras，
下一次加载不带该选项时，不继承上一媒体的外部音轨。

实现依据核对了 Context7 中 mpv 官方仓库 `/mpv-player/mpv` 的：

- `DOCS/man/input.rst`：`loadfile` 的每文件选项。
- `DOCS/man/mpv.rst`：定长 UTF-8 转义及路径列表 `-append` 的语义。
- `DOCS/man/options.rst`：外部音频和硬件解码配置。
- `include/mpv/render.h` 及 GPU-Next 文档：render context 生命周期与输出接口边界。

同时检查了项目锁定提交的实际实现，未仅依据最新文档假设旧依赖行为。

## 本机原生验证

库版本：mpv `v0.41.0-928-ge7191f2a6`，FFmpeg `N-126214-g3bdd89583`。
现有原生探针使用项目依赖的 ANGLE/D3D11 实现；本机实际渲染适配器为 AMD Radeon Graphics。

### 功能烟测

`tool/native_media_smoke.py` 通过 ctypes 调用已有 libmpv，生成仅用于测试的静音 WAV，
不访问网络、不读取账号或更改用户配置。主视频由调用者提供一个至少数秒的本地媒体文件。

```powershell
python tool/native_media_smoke.py `
  --library build/windows/x64/runner/Debug/libmpv-2.dll `
  --video <本地视频文件>
```

本机 AV1 样本通过：中文、逗号、分号、百分号路径；外部音轨被选中；主 URL 未变成 EDL；
重载保留音轨和一秒起播点；切到无独立音轨的媒体后清除旧音轨；仅音频不加载视频。
烟测使用 `vo=null` / `ao=null` / 软件解码，只证明参数与轨道生命周期，不证明 A/V 主观同步、
GPU 直通或网络 CDN 播放。

### 解码路径短测

已有原生探针 `doc/dev/artifacts/probes/decoder-diagnosis-probe.exe` 与 AV1 本地夹具进行六次独立进程测试。
顺序为 copy / direct / direct / copy / copy / direct，每轮渲染三秒，输出表面仅 64×64。
外部每约 50 ms 采样进程内存和累计 CPU 时间；表中峰值为采样峰值，非系统全生命周期峰值。

| 请求配置 | 实际解码器 | 三轮 Private Bytes 采样峰值（MiB） | 三轮采样峰值平均（MiB） |
| --- | --- | --- | --- |
| `auto-copy` | `d3d11va-copy` | 184.17 / 184.54 / 185.09 | 184.60 |
| `d3d11va,no` | `d3d11va` | 157.23 / 155.58 / 155.90 | 156.24 |

这组有限条件下，direct 的 Private Bytes 采样峰值平均低 **28.36 MiB（约 15.4%）**。
这不是完整应用 RSS、GPU 显存或长期泄漏的测量，也不能外推成整应用省内存 15.4%。

累计 CPU 采样末值：copy 为 1250.0 / 1250.0 / 1140.6 ms；direct 为
1078.1 / 1171.9 / 1156.2 ms。观测含启动成本、样本很短且区间重叠，**不足以声称稳定 CPU 提升**。
所有进程退出码为零，播放位置均推进至约 2.93–2.97 秒。

本机原始结果在 `build/native-playback-probe/summary.json`；原生探针和媒体夹具是本机已有、
未纳入版本控制的实验产物，不假设其他检出环境具备这些文件。

## 验证命令与仍需实机确认的范围

```powershell
flutter test --no-pub
flutter analyze --no-pub lib test
flutter build windows --debug --no-pub
```

本次执行结果：

| 检查 | 结果 |
| --- | --- |
| 全仓 Flutter 测试 | 239 项通过 |
| 播放器代码与测试的定向 analyze | 无问题 |
| 全量 `lib test` analyze | 28 项 info，均在本次未改动的 `lib/common/widgets/flutter/` 定制控件中；退出码 1，不能记为全量检查通过 |
| Windows Debug 构建 | 成功 |
| 本机 libmpv 直载烟测 | 四组检查通过 |

针对性回归覆盖显式 copy 选择、新默认策略、外部音轨、同轮多次请求合并、
同步重入、异步异常后继续加载，以及销毁时的请求失效。

尚需实机确认：Android 播放；真实 CDN DASH 的起播/拖动/切清晰度及 A/V 同步；
带弹幕的完整窗口长测；多适配器/显卡驱动；HDR、超分辨率、全屏与 PiP。

已保存旧 `auto-copy` 设置的用户需要在“硬解模式”中选择 `d3d11va`、`auto` 顺序，
才会启用新默认同等路径；本次不擅自迁移其显式选择。
### 已记录、未扩展修改的页面归属问题

当前播放回调仍是共享静态字段。若页面 B 已替换回调但 URL 尚未返回、还未提交新的
`setDataSource`，页面 A 的加载代次并不会因此失效；A 完成时可能调用 B 的回调。
多个直播页甚至共享同一播放器 `play` 方法，不能简单用回调相等判定页面归属。
本次没有把“新加载请求的失效”误当成完整的导航所有权模型，也没有改动页面生命周期；
后续需要独立的页面 owner/token 与导航回归覆盖。此为现存调用链的静态发现，未做 UI 复现。

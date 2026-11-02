# 弹幕与帧呈现

## 先分清时钟和观察点

更新次数、Flutter Build/Raster 时间、GPU 提交和屏幕实际呈现分别回答不同问题。采集时保留帧目标时间、回调执行时间、位移、Raster、提交与实际呈现的关联；缺少对应帧时标记缺失，不用相邻记录补点。诊断包的 250 ms 聚合数据适合确定调查方向，不能逐帧解释其中每个空档。

2026-10-20 的回归复现了两个时钟问题：回调越过帧目标后，旧唤醒补偿失效，将仍可到达的更新推迟一屏；运动位置使用回调执行时间，使交付抖动转化为位移抖动。修复后，运动使用帧目标时间，暂停和资源期限仍使用实际单调时间。对应调度和显示组件测试通过。

## Android：取图、提交和显示分开测

2026-10-15 的主机回归中，120 次重绘、30 次视频帧通知原先造成 120 次原生取图；修正后为 30 次。复测时固定视频、帧率档位、刷新率、解码路径与采样窗口，同时测取图频率和 Raster。

10 月 21 日的 EGL 呈现时间实验在部分片段改善相位，但同策略复采及其他帧率未稳定通过既定连续性阈值。设置时间戳不能补回已错过的 deadline；后续验证应贯通 UI 请求、Raster、swap、系统 deadline 与实际 present。

## Windows：显示证据和回退路径

2026-10-22 本机 165 Hz Profile 引擎实验中，最终 DirectComposition 方案的八组纯弹幕及视频背景场景通过当时的连续性判定。早期只限制排队或调整相位的候选存在失败复采；隐藏窗口数据未用于正常可见播放比较。探针记录已显示帧的关联率和覆盖率，避免将提交时间误当成实际显示时间。

采集使用合成点播时钟、本地消息和本地视频纹理；DirectComposition 回退路径仍待验证。

历史记录：`doc/dev/diagnostics/reports/danmaku-frame-clock-root-cause-20261020.md`、`danmaku-output-deadline-20261021.md`；`doc/dev/android-performance/android-jank-texture-acquisition-20261015.md`；`doc/dev/diagnostics/windows-danmaku-validation/report.md`。

# 排障经验与历史结论

这里汇总 2026 年 10 月至 11 月的排障经验。结果对应当时的版本、设备和负载，复用前请核对当前环境。播放器维护入口见[架构](../development/architecture.md)和[维护与排障](../maintenance/troubleshooting.md)。

- [播放与直播](playback.md)：音轨中断、退出挂起、黑闪与超分切换。
- [弹幕与帧呈现](frame-pacing.md)：区分帧目标、回调交付和实际显示，以及平台实验结果。
- [内存与诊断开销](memory-and-diagnostics.md)：页面回收、GPU 高水位、诊断采样对卡顿的影响。
- [首页加载](feed-loading.md)：拆分请求等待、过滤和首屏布局的排查方法。

各篇末尾列出本机历史记录。`doc/dev/` 不随 Git 提交，部分原始采集和旧构建已清理。

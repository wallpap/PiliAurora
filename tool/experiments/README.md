# 按需实验

在仓库根目录通过 FVM 运行，使用与正式测试相同的项目依赖：

```powershell
fvm flutter test tool/experiments/
```

此目录不进入默认 `fvm flutter test` 的 `test/` 扫描。可将单个文件路径传给命令，独立运行对应实验。

| 文件 | 内容 |
| --- | --- |
| `danmaku/raster_cache_capacity_test.dart` | 对照 16/24/32 MiB 缓存容量在唯一内容、重复内容和预热扫描中的命中、光栅化与淘汰；检查预算和预期命中关系。 |
| `danmaku/legacy_danmaku_rebuild_test.dart` | 测量旧弹幕渲染器在 120 个动画帧中的 widget 重建数和 pump 时间；重建数作为测量结果输出。 |

测量使用 Flutter 测试宿主，pump 时间受本机与缓存状态影响，不代表实际 GPU 帧耗时。当前 Windows 渲染器的逐帧重建、图片复用、预算和绘制行为仍在 `test/pages/danmaku/` 中验证。

# Windows Raster Cache 淘汰研究（2026-10-03）

## 范围与结论

- 仓库：`E:\Code\project\PiliAurora`；分支：`codex/windows-playback-experiments-20261003`。
- 只读快照：HEAD `170ffd7b65ee7249fae61a47e0e6bc6981aff739`，2026-10-03 18:25（UTC+08:00）。工作树已有主代理改动；以下行号对应读取时的工作树，不等同于 HEAD 文件。
- 仅新增本报告。不修改实现、测试、依赖、共享 Pub 缓存；不安装、不暂存、不提交、不启动播放器。没有运行 Flutter tests，以保持“仅写报告”的边界；下列代码是交给主代理执行的实验方案。
- **没有找到当前 renderer 调用链上已证实的 image 失效、字节预算突破或 double-dispose bug。** 找到了确定的布局条目污染行为，以及可复现的独立 `rasterize` 自淘汰边界；是否改变 admission / LRU 策略，应明确验收契约。
- **不能由高淘汰数推出应增大缓存。** 先分开观察“布局淘汰”“图片淘汰”“有用预热”，再做 16 / 24 / 32 MiB 对照。

## 一手证据索引

正文的 `[R…:行号]` 对应以下绝对路径；样本只报告数值，不展示原始弹幕或媒体正文。

| ID | 精确源码路径 / 固定版本 |
| --- | --- |
| R1 | `E:\Code\project\PiliAurora\lib\pages\danmaku\raster_cache.dart` |
| R2 | `E:\Code\project\PiliAurora\lib\pages\danmaku\windows_renderer.dart` |
| R3 | `E:\Code\project\PiliAurora\test\pages\danmaku\windows_renderer_test.dart` |
| R4 | `E:\Code\project\PiliAurora\lib\pages\danmaku\view.dart` |
| R5 | `E:\Code\project\PiliAurora\tool\danmaku_playback_benchmark.dart` |
| R6 | `E:\Pub\Cache\git\canvas_danmaku-275046d8647a6a26cba1d0dadb9e28688cb3dbf1\lib\utils\utils.dart` |
| R7 | `E:\Pub\Cache\git\canvas_danmaku-275046d8647a6a26cba1d0dadb9e28688cb3dbf1\lib\models\danmaku_item.dart` |
| R8 | `E:\SDK\fvm\versions\3.47.5\bin\cache\pkg\sky_engine\lib\ui\painting.dart`，本地 `engine.version = af7e796e161ae0bb1ff0758c71a7105418bd9ded` |
| R9 | `E:\SDK\fvm\versions\3.47.5\bin\cache\dart-sdk\lib\collection\linked_hash_map.dart` |
| R10 | `E:\Code\project\PiliAurora\tool\danmaku_benchmark.dart` |

锁定依据：`E:\Code\project\PiliAurora\pubspec.lock:232–240`、`E:\Code\project\PiliAurora\.dart_tool\package_config.json`。canvas_danmaku 为 0.2.6 / commit `275046d8647a6a26cba1d0dadb9e28688cb3dbf1`；Flutter 包解析指向 3.47.5。官方文档搜索及固定 commit 的远程源码读取未返回可用内容，故结论以这些本地锁定一手源码为准，而非最新在线文档。

文件指纹：R1 SHA256 `1539395DC79E9D79D127514E8793DCCDD48B7A70879E4026FCC302630A21FF48`；R2 SHA256 `3CF0F20F878ABF8FE633EB30A483AA9F909CA055427814B9D4145827C2519895`。

## 1. LRU 与预算的实际契约

| 检查项 | 确认结果 |
| --- | --- |
| 排序 | Map literal 是插入有序 LinkedHashMap。`get` 先 remove 再 insert，因此命中、布局 miss 都进入 MRU；`_trim` 删除首项。属于 **get 驱动的统一条目 LRU**，不是只对图片、成功入场或绘制使用计时的 LRU。[R9:7–24；R1:88–143] |
| 不刷新 | `isRasterized` 只窥视；`rasterize(content, entry)` 本身不更新顺序。已缓存内容被 queuePrewarm 跳过时，也不刷新顺序。[R1:54–55,65–85；R2:322–335] |
| 尚未栅格化 | 每项 `entry.bytes` 在布局时已算出，但总 `cache.bytes` 只在生成 image 后增加。布局项占条目槽位、持有 Paragraph，却不占 **image 账面字节**。[R1:8–15,79–82,117–130] |
| 尺寸 / 单项拒绝 | 即使只请求布局，也先按预测图片尺寸检查 4096 上限、2 MiB 单项限制及 maxBytes；不合格项 dispose Paragraph 且不入缓存。被拒布局尝试仍计入 layouts。[R1:95–122] |
| 淘汰零字节项 | 字节超限时，仍按统一 LRU 从首项逐个删；删除布局项不减少 bytes，所以会继续删除后续项。布局项不占图片预算，但能成为字节压力下的牺牲项。[R1:135–144] |
| key | text、ARGB color、isColorful、selfSend、count；普通滚动 / 顶部 / 底部可共享同一图片。字号、DPR、字体等不在 key 内，renderer configure 通过清缓存使其失效。[R1:57–63；R2:446–458] |

**独立 API 边界，尚非 renderer 已确认故障：** 令等大 A / B 各为 b 字节，cache.maxBytes=b。先 `get(A)` 仅布局，再 `get(B, rasterize:true)`，最后 `rasterize(A, entryA)`。顺序仍是 A→B；生成 A 后超预算，`_trim` 会销毁刚生成的 A，最后返回 null。若定义“栅格化成功使用也须成为 MRU”，这就是应修的边界缺陷；若明确 API 要求先 get 刷新，则需文档化约束。当前 add 是 get→同步 rasterize，prewarm/configure 是 get(rasterize:true)，没有在这两步之间异步交错，因此此序列不能直接证明播放路径丢弹幕。[R1:65–85,93–130；R2:250–305,364–367,479–485]

## 2. 拒绝与预热的缓存污染

### 拒绝轨道 / 活动预算：确定行为，策略未定

普通弹幕在活动预算及轨道判定之前执行 `rasters.get(content)`。因此：

1. 新文本即使随后被轨道或活动预算拒绝，也会留下布局项。
2. 命中旧文本但随后拒绝，仍会增加 hits 并提升 MRU。
3. 布局项增加 length，条目上限可因此淘汰有图片的旧项。
4. 轨道拒绝本身不调用 rasterize，所以不会因这一次 add 新增 image bytes；它仍可能持有更早预热的图片。

早期的隐藏类型、无轨道、600 活动项等拒绝在 get 之前，不走上述路径。[R2:202–213,250–299]

**最小策略红测：** maxEntries=1，先接受顶部 A，再提交因唯一静态轨道被占而拒绝的顶部 B。当前 A 的 cache handle 已被 B 的布局项挤出，bytes 从 b 降到 0，布局 B 留在缓存；A 的活动 clone 仍有效。若目标契约为“仅布局的拒绝项不能驱逐已缓存图片”，则对 `isRasterized(A)==true` 的断言会红。这不是现有 budget 越界或 use-after-free。[R1:126–142；R2:250–305]

合理备选是将布局缓存与图片缓存分开，或对未入场布局做有限 probation，先保留现有 16 MiB 图片上限。**不建议简单 pin 所有活动图片**：活动预算为 96 MiB；pin 会把 16 MiB cache 上限变成另一种契约，也不能阻止一次性预热生成无用图片。直接不缓存任何拒绝布局也会增加重复拒绝文本的 layout 开销，应通过实验比较，而非作为无条件修复。[R2:54–68；R1:30–32]

### 预热：确定可竞争缓存，未证明净收益

- 队列最多 64 key，每批最多 4 项；2 ms 是进入下一次循环前检查，不是单次栅格化的硬时间上限。[R2:64,322–368]
- 只过滤 special、隐藏类型和已栅格化 key；不检查未来轨道 admission 或活动预算。真实 view 每约 500 ms 看缓冲中未来 100–2000 ms 的普通弹幕；基准同样看未来 2 秒。[R2:322–335；R4:218–238；R5:391–416]
- `prewarmPending` 使用普通 get(rasterize:true)，与需求入场使用同一 LRU。未来永不入场、来不及入场、或一次性文本仍能生成 image 并驱逐需求图片。[R2:357–367；R1:126–143]
- 已由 add 生成 image 的 pending 项仍可能在稍后被 get 命中；若图片先被淘汰，它又可能重新生成。queue 的跳过检查只发生在排队当时。[R2:329,364–367]
- `prewarmed` 仅为预热调用期间 rasterizations 的增量，不表示预热后被接受、被绘制或真正避免了关键路径栅格化。cacheHits 也包含布局命中、预热命中及被拒绝 add 命中，不是可直接使用的需求 image hit rate。[R1:123–125；R2:365–367]

这些是可测的投机缓存成本，不是仅凭源码就能定性的性能 bug。可测试“需求图片保护 / 预热低优先级”，但不先引入复杂替换算法。

## 3. 共享 image 生命周期与内存口径

- cache 持有原 handle；正常入场的 DanmakuItem 持有 `image.clone()`。clone 共享 native backing，不复制整张像素；cache 淘汰只 dispose 自己的 handle，活动 clone 仍可使用。[R2:299–305；R8:2012–2031,2177–2202]
- 活动项到期 / clear 调用 item.dispose，释放自己的 handle；renderer.dispose 先 clear 活动项，再 rasters.clear。`renderer.clear()` 刻意保留 cache，`rasters.clear()` 则可在活动图片仍存活时独立执行。[R2:379–411,627–647；R7:37–40]
- cache.clear 会把 entries / bytes 归零，但不增加 evictions，也不清零 layouts / hits / rasterizations / eviction reason 计数。实验必须从同一实例的 before/after 做差，或新建实例；不能把 clear 当成统计重置。[R1:135–153]
- `cacheImageBytes` 是缓存内 image 条目的 `ceil(width×DPR)×ceil(height×DPR)×4`；锁定 DmUtils 的 toImageSync 尺寸计算与此一致。它不包含 Paragraph、handle / 引擎对象、驱动分配、纹理对齐、图形后端驻留、延迟释放等。[R1:101–118；R6:59–60,117–127]
- `activeImageBytes` 按每个活动 item 累加，即使多个 item 共享 backing 也重复计数；普通项生成 / 释放采用同一像素尺寸的账面值。[R2:255,305,317,408–411]
- **不得把 activeImageBytes 与 cacheImageBytes 相加解释成实际 RAM / VRAM。** 缓存淘汰不保证立即释放 backing：它可能仍被活动 clone 持有。之后同 key 再 miss 会创建另一 backing，旧 clone 仍存活时两份可并存；大小收益必须结合实际进程与 GPU 指标验证。[R8:2012–2031,2193–2202；R1:95–122；R2:305]

现有生命周期测试只检查淘汰后 clone.width>0；width 是 final Dart 字段，单独读取它不足以证明 native 图片还能绘制。建议补实际 `toByteData` / 像素比对与 dispose 后 handle 检查。[R3:181–200；R8:2004–2008]

## 4. 淘汰统计：压力归因，不是互斥的释放原因

每次 `_trim` 迭代，在删除之前检查两项超限条件：

- evictions：删除了多少缓存项，含布局和 image。
- evictionsByBytes：删除之前 bytes>maxBytes 的迭代数，含本次释放 0 image 字节的布局项。
- evictionsByEntries：删除之前 length>maxEntries 的迭代数，含两项同时超限的迭代。
- 两个 reason 都可能增加；每个 reason≤evictions，且 evictions≤两个 reason 之和≤2×evictions。clear 不在其中。[R1:135–153]

最小确定样例：L 为布局，A/B 为等大图片，maxEntries=2、maxBytes=b。get(L)、get(A,rasterize:true)、get(B,rasterize:true) 后先删 L（双超限、释放 0 图片字节），再删 A（仅字节超限）；总 evictions=2、ByBytes=2、ByEntries=1。把两个 reason 相加成“3 次淘汰”，或者宣称“2 张图片被字节预算驱逐”都错误。

合理观测补充（建议，不在本轮实施）：evictedLayouts / evictedImages / evictedAccountedImageBytes；需求 image hit / layout-only hit；预热生成后首次成功 admission / 未使用就淘汰。新增计数应保持原有压力计数语义，避免破坏旧样本对比。

## 5. 现有数值样本复核

原始文件：

- `E:\Code\project\PiliAurora\build\playback-20261003-smoke\smoke.json`
- `E:\Code\project\PiliAurora\build\playback-20261003-reset-smoke\smoke.json`
- `E:\Code\project\PiliAurora\build\playback-20261003-graceful-smoke\smoke.json`

三份均为 cache=16 MiB、entries=512、prewarm=true、DPR=1.5、预热3秒 / 测量2秒；媒体窗口43042→45042 ms。每份测量接受68、拒绝243，末尾 cacheEntries=57、cacheImageBytes=16,447,500、activeImageBytes=79,841,420；累计 rasterizations=470、prewarmed=408。以下 Δ 为 JSON.statistics-statisticsBefore，不混用累计量。

| 样本 | Δlayouts | Δhits | Δrasterizations | Δevictions / ΔByBytes | ΔByEntries | Δprewarmed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| smoke | 244 | 156 | 174 | 245 | 0 | 145 |
| reset-smoke | 236 | 156 | 166 | 217 | 0 | 137 |
| graceful-smoke | 232 | 156 | 162 | 207 | 0 | 133 |

累计 evictions 分别为532/539/539，**比累计 rasterizations=470 多62/69/69**。按当前每次 image 创建增加一次 rasterizations 的实现，至少这些差额只能是布局项淘汰，不能是图片淘汰。这是由数值与源码联合得出的下界，不是完整分类计数。ΔByEntries=0 只说明这些窗口没有条目上限压力，不能说明布局项没有污染 LRU。

累计 prewarmed/rasterizations=408/470≈86.8%，只说明生成来源；不能解释为86.8%有效预热。三份样本测量期 rejectByTrack 增量都是187，活动预算拒绝增量为0；外围拒绝和 renderer 拒绝应分开，轨道成因交给另一研究处理。

同一16 MiB预算的末尾 RSS 分别594,927,616 / 522,747,904 / 547,741,696，privateBytes 约608–612百万字节。不能用单个短窗口的 RSS 差归因缓存容量；三份进程后续退出均失败，仅能用于遥测字段复核，不作为稳定性或缓存性能验收。（退出状态记录：`E:\Code\project\PiliAurora\tool\reports\windows-playback-experiment-20261003.md:1–11,47–78`。）

旧合成样本 `E:\Code\project\PiliAurora\build\danmaku-benchmark-profile-current.json` 与 `E:\Code\project\PiliAurora\build\danmaku-benchmark-profile-final2.json`：repeated 只有12 key、约524,688 cache字节、0淘汰；unique 为360布局 / 栅格化、334末尾条目、26淘汰、16,735,548 cache字节。合成 unique 的预热始终来自紧接将入场的序列，[R10:103–122]，不能代表真实数据的轨道拒绝 / 无效预热；它只能证明当时存在容量压力。旧样本缺新的 reason 计数和窗口字段，不混成同一组实验。

## 6. 离线实验一：最小回归包

主代理可以在 `E:\Code\project\PiliAurora\test\pages\danmaku\raster_cache_policy_test.dart` 放入下列代码。此文件本轮**未创建**。全部使用 flutter_tester，不依赖 mpv、WebView、网络或 Windows 原生窗口。

第一项是当前实现预计会失败的**策略红测**：需先同意“拒绝布局不驱逐图片”的契约。第二项是当前语义的通过型观测测试；若以后刻意改策略，可调整淘汰预期，但仍保持 clone 能取像素的生命周期断言。

```dart
import 'dart:ui' as ui;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/raster_cache.dart';
import 'package:pili_aurora/pages/danmaku/windows_renderer.dart';

const option = DanmakuOption(fontSize: 20, duration: 2, staticDuration: 1);
DanmakuContentItem<void> text(String s, int color,
    {DanmakuItemType type = DanmakuItemType.scroll}) =>
  DanmakuContentItem<void>(s, color: Color(color), type: type);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('拒绝的布局不应驱逐已缓存图片（候选策略红测）', () async {
    final r = WindowsDanmakuRenderer<void>(
      option: option.copyWith(area: 0.3, safeArea: false,
          massiveMode: false, static2Scroll: false),
      size: const Size(320, 120), rasterCacheMaxEntries: 1,
    );
    addTearDown(r.dispose);
    expect(r.controller.trackCount, 1);
    final a = text('same', 0xffffffff, type: DanmakuItemType.top);
    final b = text('same', 0xffff0000, type: DanmakuItemType.top);
    expect(r.add(a), isTrue);
    final active = r.staticDanmaku.single!.image!;
    final before = await active.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytesBefore = r.activeBytes;
    expect(r.add(b), isFalse);
    expect(r.rejectedByTrack, 1);
    expect(r.rasters.rasterizations, 1);
    expect(r.activeBytes, bytesBefore);
    final after = await active.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(after!.buffer.asUint8List(), before!.buffer.asUint8List());
    // 当前实现这里为 false；前面的生命周期断言应通过。
    expect(r.rasters.isRasterized(a), isTrue);
  });

  test('零字节布局淘汰也计入字节压力；clone保留native图片', () async {
    final probe = DanmakuRasterCache(option: option, devicePixelRatio: 1);
    final a = text('same', 0xffffffff);
    final b = text('same', 0xffff0000); // 相同文本、不同key、相同尺寸。
    final budget = probe.get(a)!.bytes;
    probe.clear();
    final c = DanmakuRasterCache(option: option, devicePixelRatio: 1,
        maxBytes: budget, maxEntries: 2);
    addTearDown(c.clear);
    c.get(text('same', 0xff00ff00)); // 布局项也要等宽，避免单项预算拒绝。
    final aEntry = c.get(a, rasterize: true)!;
    final image = aEntry.image!;
    final clone = image.clone();
    addTearDown(clone.dispose);
    final before = await clone.toByteData(format: ui.ImageByteFormat.rawRgba);
    c.get(b, rasterize: true);
    expect(c.evictions, 2);
    expect(c.evictionsByBytes, 2);
    expect(c.evictionsByEntries, 1);
    expect(aEntry.image, isNull);
    expect(image.debugDisposed, isTrue);
    expect(clone.isCloneOf(image), isTrue);
    expect(clone.debugDisposed, isFalse);
    c.clear();
    expect(c.bytes, 0);
    expect(c.evictions, 2); // clear不增加计数。
    final after = await clone.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(after!.buffer.asUint8List(), before!.buffer.asUint8List());
  });
}
```

执行（主代理创建测试后）：

```powershell
flutter test --no-pub E:\Code\project\PiliAurora\test\pages\danmaku\raster_cache_policy_test.dart
```

可在同一回归包追加三个短观测，不要混成一个强制改策略的断言：

1. **LRU提升**：maxEntries=2，A/B 栅格化→get(A)命中→C栅格化；应淘汰B而保留A/C。用不同color、相同text保证同尺寸，检查 retained entry.image 是否为null，而不是再get造成新布局。
2. **独立rasterize自淘汰**：按第1节 A布局→B栅格→直接A栅格的序列；当前返回null、B仍栅格化。若采纳栅格使用即MRU的契约，红测改成非null且A保留。
3. **预热污染观测**：maxEntries=1、先接受顶部A，queuePrewarm([顶部B])→prewarmPending；B尚未入场就使A离开cache，A活动clone像素不变；随后add(B)因静态轨道占用拒绝。预热批次受2ms检查影响，应有限次数推进或pump到pending=0后再断言，不依赖一次调用一定完成。此观测不要求永久pin A，也不等于需要禁止预热。

所有 test 都应 teardown cache / renderer / 克隆 handle。严格MRU、统一预算和生命周期测试应先保持绿色；策略红测只在契约确定后作为实现验收。

## 7. 离线实验二：16 / 24 / 32 MiB 容量与投机污染对照

### 先用 Flutter tests 做确定性账面回放

不用睡眠、Scheduler 或真实帧时间，直接同步回放 DanmakuRasterCache 访问序列；字体和DPR固定为实验参数。建议用上述imports / text / option，在独立test内：

```dart
final probe = DanmakuRasterCache(option: option, devicePixelRatio: 1.5);
final bytes = probe.get(text('x' * 64, 0xff000001))!.bytes;
probe.clear();
final n = (28 * 1024 * 1024 + bytes - 1) ~/ bytes;
expect(n, lessThanOrEqualTo(512));
expect(n * bytes, lessThanOrEqualTo(32 * 1024 * 1024));
final items = List.generate(n, (i) => text('x' * 64, 0xff000001 + i));
for (final mib in [16, 24, 32]) {
  final c = DanmakuRasterCache(option: option, devicePixelRatio: 1.5,
      maxBytes: mib * 1024 * 1024, maxEntries: 512);
  try {
    // 模拟按顺序投机预热整批工作集。
    for (final item in items) { c.get(item, rasterize: true); }
    final before = c.rasterizations;
    var demandImageHits = 0;
    // 需求按相同顺序扫描；先窥视，避免get改变命中判定。
    for (final item in items) {
      if (c.isRasterized(item)) demandImageHits++;
      c.get(item, rasterize: true);
      expect(c.bytes, lessThanOrEqualTo(c.maxBytes));
    }
    final demandRasterizations = c.rasterizations - before;
    expect(demandImageHits, mib == 32 ? n : 0);
    expect(demandRasterizations, mib == 32 ? 0 : n);
  } finally { c.clear(); }
}
```

该约28 MiB循环扫描是**人为容量悬崖**：16/24不足容纳全量，所以顺序需求会继续驱逐尚未访问的尾部；32可全容纳。它验证LRU行为与容量影响，不证明真实播放需要32 MiB。image尺寸按 probe 动态计算，不能硬编码某字体的估计值。

再用同一测试入口扩展两条 trace（不增实验类别）：

- **有复用 / 无复用**：同样宽度，重复12 key与全unique各跑；预热开/关形成对照。关闭预热且unique需求只扫描一次时，大缓存只保留更多一次性图片，需求栅格次数不应因此变少；开启预热时，即使只使用一次也可能避开需求路径生成，需单列此收益。
- **热集+冷扫描**：约4 MiB hot key反复需求，期间分别插入至少513个唯一key的只布局拒绝模拟流、约28 MiB栅格化预热流，观察热集image命中和layout/image淘汰。布局流按条目数设计，确保触发entries压力；预热流按账面图片字节设计，触发bytes压力。保持maxEntries=512，另用4096只作为区分条目/字节约束的诊断组，不改变生产默认值。

记录：每段前后 layouts / rasterizations / hits / 两类压力计数、显式需求image命中、布局命中、末尾entries及账面bytes。测试可另计自己持有的entry状态以区分淘汰类型，避免为了研究先改生产遥测。不要把 flutter_tester Stopwatch / CPU光栅耗时当成Windows GPU收益，也不要用此测试的资源驻留得出实际内存结论。

### 原生退出修复后再做真实播放复核

使用已有入口R5，保持同一构建、同一fixture / 起始媒体位置 / 字体 / DPR / 视口 / 硬解 / 活动96 MiB / entries512。容量与prewarm按3×2组合运行：

- `--cache-mib=16|24|32 --cache-entries=512 --prewarm=true|false --renderer=prepared --kind=stress`；参数校验在[R5:33–103]。
- 每轮容量顺序16→24→32，下一轮32→24→16，prewarm顺序也反转；建议至少3对有效轮次。每个条件新建renderer，固定暖机与较长测量窗口（如5秒+20秒），媒体数据不足或位置停滞时判为无效而非强求样本数。
- 不只比末尾累计evictions：从statisticsBefore / statistics做差。[R5:530–551,582–589]；单列无效预热、需求image命中、成功入场 / 拒绝、关键路径栅格化、FrameTiming分位数、同区间RSS/privateBytes趋势。GPU内存需独立图形诊断，不能由账面bytes推导。
- 驱动缓存、视频纹理、活动clone、预热开销都可能影响RSS。另做clear活动→clear cache→dispose阶段观察；但释放不是同步物理内存下降的保证。[R2:627–647；R8:2012–2031]
- **停止条件**：再次发生原生退出故障、媒体窗口失效、DPR/视口不一致，就停止该轮归因；不把结果文件存在当成功。不修改系统WER或用强制终止替代生命周期验收。
- **决策条件**：只有在接受/拒绝与工作负载可比、关键路径栅格化或慢帧稳定改善、实际资源趋势可接受时，才讨论容量调整；若只看到淘汰数降低，结论应为“不足以变更默认值”。

## 未验证范围

未执行本文新回归测试；未采集24/32 MiB真实Windows对照；未验证原生释放时序、实际GPU驻留、长时DPI/多屏行为。独立rasterize边界与拒绝布局驱逐是依据同步源码得到的确定路径，但尚未做本轮动态红绿。报告不覆盖WebView退出修复，也不替代轨道分配研究。

## 主代理后续验证补记

以上“未执行新测试/未新增遥测”描述的是只读研究阶段。主代理随后进行了以下验证：

- 在现有 `test/pages/danmaku/windows_renderer_test.dart` 新增 3 个动态用例：压力原因与负载分类、被拒绝布局驱逐图片但活动 clone 像素保持、独立 rasterize 自淘汰边界。全部通过。
- 在 `test/pages/danmaku/raster_cache_capacity_test.dart` 执行容量回放：约 28 MiB 工作集（116 个 key、每项 253,836 账面字节），16/24/32 MiB 对照。
- 一次性 unique 需求：三档均生成 116 张图片；增大缓存只减少保留阶段的淘汰，不减少需求生成。
- 12-key repeated：三档均 104 次需求图片命中、12 次需求生成，均无淘汰。
- 整批 prewarm 后同序扫描：16/24 MiB 均 0 次需求图片命中，32 MiB 为 116 次。该结果是人为工作集容量悬崖，不能推论实际播放器应改为 32 MiB。
- 新增 `evictedLayouts` / `evictedImages` / `evictedImageBytes`，保持旧压力计数语义。前两者互斥，和等于 evictions；后者是被删除缓存 handle 的账面图片字节，不是已释放 RAM/VRAM。
- 未采纳“拒绝布局不得驱逐图片”或独立 rasterize 必须成为 MRU 的策略变更。本轮保持现有 LRU 与生产默认 16 MiB，先用分类统计测量真实负载。
- 相关回归整组：61 项通过，日志 `E:/Code/project/PiliAurora/build/cache-followup-tests-20261003.log`。
- 本项目改动范围 analyze：No issues found，日志 `E:/Code/project/PiliAurora/build/cache-own-analysis-final-20261003.log`。

真实 Windows 矩阵与退出修复结果见 `windows-webview-cache-experiment-20261003.md`。读取以上原始源码索引时，应以研究快照为准：后续新增计数使工作区行号向后移动。

# 信息流黑名单屏蔽

## 设置

进入 **设置 → 账号与隐私 → 增强黑名单屏蔽**。默认开启，切换后刷新信息流生效。

- **增强黑名单屏蔽**：按主账号的黑名单过滤作者，并在可分页的信息流中继续加载内容补位。
- **检查合作视频作者**：位于上述开关下方，默认开启。对列表明确标识的合作视频查询合作作者，任一作者在黑名单中即屏蔽整条视频；关闭后按主投稿者过滤。

## 适用范围

| 内容入口 | 处理方式 |
| --- | --- |
| 首页推荐、热门、搜索中的视频/专栏/直播/用户、动态与话题、直播推荐与分区 | 进入页面列表前过滤；支持分页的列表沿同一来源补位。 |
| 排行、每周必看、详情页相关视频 | 过滤后按原顺序排列，保持原列表范围。 |
| 收藏、历史、稍后再看、直接打开详情 | 保留原有行为。 |

分页补位单次最多读取五页，补位页中的有效内容全部保留。真实空页、来源终点或请求失败时结束本次补位，后续加载接着未读页继续。

首页推荐按视口容量连续补足，连续五页无有效增长时停止并等待刷新；分页失败保留已有内容，点击页尾“加载失败，点击重试”可重试原页。刷新与切账号会使旧查询失效，旧响应不会进入新列表。

## 合作视频检查与请求开销

补查由列表中的 `rights.is_cooperation`、`is_union_video` 等明确合作标志触发。列表已提供合作作者名单时直接使用；没有合作标志时使用主投稿者信息。动态中的视频及转发原动态也沿用这一规则。

黑名单为空、主投稿者已被拉黑、合作作者名单已知时，会跳过补查。需要补查的合作视频通过视频详情接口读取 `staff`，检查结束后再进入列表，避免先显示再移除。

首页推荐采用渐进展示：普通卡片先显示，待检查的合作卡片在原位置显示骨架；每条检查完成后独立揭示，命中屏蔽则移除并补位。后续推荐下载与检查同时进行，合作作者查询仍沿用全局两个并发名额。

合作作者缓存保存 UID 集合，拉黑或解除后按当前黑名单重新判断。同一视频的并发补查合并为一个请求，全局最多同时执行两个补查；成功结果在本次应用运行期间缓存一小时，最多保留 256 条。失败结果缓存一分钟，期间继续按已知作者过滤。

补查会增加合作视频所在批次的请求量、流量和加载时间。关闭“检查合作视频作者”可停止该部分补查，主投稿者过滤继续生效。

黑名单本身按主账号缓存，五分钟内复用同步结果。首页推荐下载与完整名单同步同时开始，名单准备完成后再发布内容；其他发现列表在请求前同步。同步失败时沿用该账号缓存；应用内拉黑或解除操作即时更新缓存。进入黑名单管理页后，仅加载部分名单不会覆盖完整缓存。

## 实现与验证

- `lib/pages/common/discovery_list_controller.dart`：发现列表统一入口、合作作者补查及过滤。
- `lib/pages/rcmd/controller.dart`：首页容量补足、渐进展示与请求取消。
- `lib/services/cooperative_authors.dart`：合作作者查询、请求合并、并发限制及缓存。
- `lib/services/blocked_authors.dart`：主账号黑名单同步。
- `lib/utils/media_author_filter.dart`：各类卡片、动态和视频作者判定。

相关回归：

```powershell
fvm flutter test --no-pub test/pages/common/common_controller_test.dart test/pages/common/discovery_list_controller_test.dart test/services/cooperative_authors_test.dart test/services/blocked_authors_test.dart test/common/widgets/feed_pagination_test.dart
fvm flutter test --no-pub test/pages/rcmd/
fvm flutter test --no-pub test/pages/setting/settings_navigation_test.dart --plain-name '黑名单'
```

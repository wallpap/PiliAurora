import 'package:pili_aurora/models/remote/live/live_follow/item.dart';

class LiveFollowData {
  String? title;
  int? pageSize;
  int? totalPage;
  List<LiveFollowItem>? list;
  int? count;
  int? liveCount;
  // 分页按原始响应推进，离线条目过滤后空页不代表远端已经结束。
  int? sourceCount;

  LiveFollowData({
    this.title,
    this.pageSize,
    this.totalPage,
    this.list,
    this.count,
    this.liveCount,
    this.sourceCount,
  });

  LiveFollowData.fromJson(Map<String, dynamic> json) {
    title = json['title'] as String?;
    pageSize = json['pageSize'] as int?;
    totalPage = json['totalPage'] as int?;
    final source = json['list'] as List<dynamic>?;
    sourceCount = source?.length ?? 0;
    list = source
        ?.cast<Map<String, dynamic>>()
        .where((i) => i['live_status'] == 1)
        .map(LiveFollowItem.fromJson)
        .toList();
    count = json['count'] as int?;
    liveCount = json['live_count'] as int?;
  }
}

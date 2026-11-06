import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart';

/// 仅扫描本页及保留评论的预览，不读取设置、不查询用户资料。
void filterRepliesByLevel(List<ReplyInfo> replies, int minimumLevel) {
  if (minimumLevel <= 0) return;
  replies.removeWhere((reply) {
    // 缺少用户资料时保留；protobuf 中未编码的 level 默认为有效的 Lv0。
    final int? level;
    if (reply.hasMember()) {
      level = reply.member.level.toInt();
    } else if (reply.hasMemberV2() && reply.memberV2.hasBasic()) {
      level = reply.memberV2.basic.level.toInt();
    } else {
      level = null;
    }
    if (level != null && level >= 0 && level < minimumLevel) return true;
    filterRepliesByLevel(reply.replies, minimumLevel);
    return false;
  });
}

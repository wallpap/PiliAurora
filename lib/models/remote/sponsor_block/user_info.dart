import 'package:pili_aurora/utils/duration_utils.dart';
import 'package:pili_aurora/utils/num_utils.dart';

class UserInfo {
  final int viewCount;
  final double minutesSaved;
  final int segmentCount;

  const UserInfo({
    required this.viewCount,
    required this.minutesSaved,
    required this.segmentCount,
  });

  factory UserInfo.fromJson(Map<String, dynamic> json) {
    final views = json['viewCount'];
    final minutes = json['minutesSaved'];
    final segments = json['segmentCount'];
    if (views is! int ||
        views < 0 ||
        segments is! int ||
        segments < 0 ||
        minutes is! num ||
        !minutes.isFinite ||
        minutes < 0) {
      throw const FormatException('空降助手用户统计无效');
    }
    return UserInfo(
      viewCount: views,
      minutesSaved: minutes.toDouble(),
      segmentCount: segments,
    );
  }

  @override
  String toString() {
    String minutes = DurationUtils.formatTimeDuration(
      Duration(minutes: minutesSaved.round()),
    );
    if (minutes.isEmpty) {
      minutes = '0分钟';
    }
    return ('您提交了 ${NumUtils.formatPositiveDecimal(segmentCount)} 片段\n'
        '您为大家节省了 ${NumUtils.formatPositiveDecimal(viewCount)} 片段\n'
        '($minutes 的生命)');
  }
}

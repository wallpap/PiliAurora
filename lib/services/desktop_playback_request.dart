import 'package:pili_aurora/models/common/video/source_type.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';

/// 窗口间传递内容标识，播放地址仍由现有页面按账号和画质获取。
class DesktopPlaybackRequest {
  const DesktopPlaybackRequest.live(int roomId)
    : route = '/liveRoom',
      arguments = roomId;
  const DesktopPlaybackRequest.video(Map<String, dynamic> args)
    : route = '/videoV',
      arguments = args;

  final String route;
  final Object arguments;

  Map<String, dynamic> toJson() {
    final args = arguments;
    return {
      'route': route,
      'arguments': args is Map<String, dynamic>
          ? {
              ...args,
              'videoType': (args['videoType'] as VideoType).name,
              if (args['sourceType'] is SourceType)
                'sourceType': (args['sourceType'] as SourceType).name,
              if (args['entry'] is BiliDownloadEntryInfo)
                'entry': (args['entry'] as BiliDownloadEntryInfo).toJson(),
            }
          : args,
    };
  }

  factory DesktopPlaybackRequest.fromJson(Map<String, dynamic> json) {
    if (json['route'] == '/liveRoom') {
      final roomId = json['arguments'] as int;
      if (roomId <= 0) throw const FormatException('直播间 ID 无效');
      return DesktopPlaybackRequest.live(roomId);
    }
    if (json['route'] != '/videoV') throw const FormatException('播放页面无效');
    final args = Map<String, dynamic>.from(json['arguments'] as Map);
    args['videoType'] = VideoType.values.byName(args['videoType'] as String);
    if (args['sourceType'] is String) {
      args['sourceType'] = SourceType.values.byName(args['sourceType']);
    }
    if (args['entry'] is Map) {
      args['entry'] = BiliDownloadEntryInfo.fromJson(
        Map<String, dynamic>.from(args['entry']),
      );
    }
    return DesktopPlaybackRequest.video(args);
  }
}

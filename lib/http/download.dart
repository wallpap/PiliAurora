import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/video/audio_quality.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/models/remote/download/bili_download_media_file_info.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/extension/iterable_ext.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/video_utils.dart';
import 'package:collection/collection.dart';

abstract final class DownloadHttp {
  static const String referer = "https://www.bilibili.com/";
  static const String userAgent = "Bilibili Freedoooooom/MarkII";

  static int selectAudioQuality(List<int> audioIds, int preferredAudioQuality) {
    int closestNumber = audioIds.contains(preferredAudioQuality)
        ? preferredAudioQuality
        : audioIds.findClosestTarget(
            (e) => e <= preferredAudioQuality,
            (a, b) => a > b ? a : b,
          );
    if (audioIds.every((e) => e > preferredAudioQuality)) {
      closestNumber = AudioQuality.k192.code;
    }
    return audioIds.contains(closestNumber) ? closestNumber : audioIds.first;
  }

  /// 请求失败抛出保留业务码的 [Error]；响应缺少可下载媒体时抛出 [FormatException]。
  static Future<BiliDownloadMediaInfo> getVideoUrl({
    required BiliDownloadEntryInfo entry,
    int? preferredAudioQuality,
    SourceInfo? source,
    PageInfo? pageData,
    EpInfo? ep,
  }) async {
    final isLogin = Accounts.get(AccountType.video).isLogin;
    final res = await VideoHttp.videoUrl(
      avid: entry.avid,
      bvid: entry.bvid,
      cid: entry.cid,
      seasonId: entry.seasonId,
      epid: ep?.episodeId,
      qn: entry.preferedVideoQuality,
      tryLook: !isLogin && Pref.p1080,
      videoType: switch (ep?.from) {
        'pugv' => VideoType.pugv,
        != null when isLogin => VideoType.pgc,
        _ => VideoType.ugc,
      },
    );
    if (res case Success(:final response)) {
      final dash = response.dash;
      if (dash != null) {
        final videos = dash.video;
        if (videos == null || videos.isEmpty) {
          throw const FormatException('下载响应缺少视频流');
        }
        // accept_quality 可能列出账号无权下载的画质，只从实际返回的流中选择。
        final targetVideoQa = videos
            .map((e) => e.quality.code)
            .toList()
            .findClosestTarget(
              (quality) => quality <= entry.preferedVideoQuality,
              (a, b) => a > b ? a : b,
            );

        /// 优先顺序 设置中指定解码格式 -> 当前可选的首个解码格式
        final targetSupportFormats = response.supportFormats?.firstWhereOrNull(
          (e) => e.quality == targetVideoQa,
        );

        /// 取出符合当前画质的videoList
        final videosList = videos
            .where((e) => e.quality.code == targetVideoQa)
            .toList();

        /// 取出符合当前解码格式的videoItem
        final codecs = videosList
            .map((e) => e.codecs)
            .whereType<String>()
            .toList();
        final currentDecodeFormats = codecs.isEmpty
            ? null
            : VideoUtils.selectCodec(codecs, Pref.preferCodecs);
        final videoDash = currentDecodeFormats == null
            ? videosList.first
            : videosList.firstWhere(
                (e) =>
                    e.codecs != null &&
                    currentDecodeFormats.codes.any(e.codecs!.startsWith),
                orElse: () => videosList.first,
              );
        if (videoDash.playUrls.isEmpty) {
          throw const FormatException('下载响应缺少视频地址');
        }

        final videoUrl = VideoUtils.getCdnUrl(videoDash.playUrls);

        final Type2File videoFile = Type2File(
          id: videoDash.id,
          baseUrl: videoUrl,
          bandwidth: videoDash.bandWidth ?? 0,
          codecid: videoDash.codecid ?? 0,
          size: 0,
          md5: '',
          noRexcode: false,
          frameRate: videoDash.frameRate ?? '',
          width: videoDash.width ?? 0,
          height: videoDash.height ?? 0,
          dashDrmType: 0,
        );
        List<Type2File>? audioFileList;
        final List<AudioItem>? audioDashList = dash.audio;
        if (audioDashList != null && audioDashList.isNotEmpty) {
          final preferAudioQa = preferredAudioQuality ?? Pref.defaultAudioQa;
          final List<int> audioIds = audioDashList
              .map((map) => map.id)
              .toList();
          final closestNumber = selectAudioQuality(audioIds, preferAudioQa);
          final AudioItem audioDash = audioDashList.firstWhere(
            (e) => e.id == closestNumber,
          );
          if (audioDash.playUrls.isEmpty) {
            throw const FormatException('下载响应缺少音频地址');
          }
          final audioUrl = VideoUtils.getCdnUrl(
            audioDash.playUrls,
            isAudio: true,
          );
          audioFileList = [
            Type2File(
              id: audioDash.id,
              baseUrl: audioUrl,
              bandwidth: audioDash.bandWidth ?? 0,
              codecid: audioDash.codecid ?? 0,
              size: 0,
              md5: '',
              noRexcode: false,
              frameRate: audioDash.frameRate ?? '',
              width: audioDash.width ?? 0,
              height: audioDash.height ?? 0,
              dashDrmType: 0,
            ),
          ];
        }
        entry
          ..mediaType = 2
          ..hasDashAudio = audioFileList != null
          ..typeTag = targetVideoQa.toString()
          ..videoQuality = targetVideoQa
          ..preferedVideoQuality = targetVideoQa
          ..qualityPithyDescription =
              targetSupportFormats?.newDesc ??
              VideoQuality.fromCode(targetVideoQa).desc;
        return Type2(
          duration: dash.duration ?? entry.totalTimeMilli ~/ 1000,
          video: [videoFile],
          audio: audioFileList,
          referer: referer,
          userAgent: userAgent,
        );
      } else {
        final first = response.durl?.firstOrNull;
        if (first == null || first.playUrls.isEmpty) {
          throw const FormatException('下载响应缺少媒体地址');
        }
        final List<Type1Segment> segmentList = [
          Type1Segment(
            backupUrls: [],
            bytes: first.size!,
            duration: first.length!,
            md5: '',
            metaUrl: '',
            order: first.order!,
            url: VideoUtils.getCdnUrl(first.playUrls),
          ),
        ];
        final FormatItem? formatItem = response.supportFormats
            ?.firstWhereOrNull((e) => e.quality == response.quality);
        final String description =
            formatItem?.newDesc ?? VideoQuality.clear480.desc;
        final int targetVideoQa =
            formatItem?.quality ?? VideoQuality.clear480.code;

        entry
          ..mediaType = 1
          ..hasDashAudio = false
          ..typeTag = targetVideoQa.toString()
          ..videoQuality = targetVideoQa
          ..preferedVideoQuality = targetVideoQa
          ..qualityPithyDescription = description;

        final List<Type1PlayerCodecConfig> playerCodecConfigList = [
          Type1PlayerCodecConfig(
            player: "IJK_PLAYER",
            useIjkMediaCodec: false,
          ),
          Type1PlayerCodecConfig(
            player: "ANDROID_PLAYER",
            useIjkMediaCodec: false,
          ),
        ];

        return Type1(
          from: pageData?.from ?? ep?.from,
          quality: entry.preferedVideoQuality,
          typeTag: entry.typeTag,
          description: description,
          playerCodecConfigList: playerCodecConfigList,
          segmentList: segmentList,
          parseTimestampMilli: 0,
          availablePeriodMilli: 0,
          isDownloaded: false,
          isResolved: true,
          timeLength: 0,
          marlinToken: '',
          videoCodecId: 0,
          videoProject: true,
          format: response.format!,
          playerError: 0,
          needVip: false,
          needLogin: false,
          intact: false,
          referer: referer,
          userAgent: userAgent,
        );
      }
    } else {
      if (res is Error) throw res;
      throw StateError('下载地址仍在加载，未取得媒体结果');
    }
  }
}

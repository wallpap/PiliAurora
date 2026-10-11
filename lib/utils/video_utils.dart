import 'package:pili_aurora/models/common/video/cdn_type.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/models/common/video/video_decode_type.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/codec.dart';
import 'package:pili_aurora/utils/extension/iterable_ext.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

abstract final class VideoUtils {
  static CDNService cdnService = Pref.defaultCDNService;
  static String? liveCdnUrl = Pref.liveCdnUrl;
  static bool disableAudioCDN = Pref.disableAudioCDN;

  static const _proxyTf = 'proxy-tf-all-ws.bilivideo.com';

  static final _mirrorRegex = RegExp(
    r'^https?://(?:upos-\w+-(?!302)\w+|(?:upos|proxy)-tf-[^/]+)\.(?:bilivideo|akamaized)\.(?:com|net)/upgcxcode',
  );

  static final _mCdnTfRegex = RegExp(
    r'^https?://(?:(?:(?:\d{1,3}\.){3}\d{1,3}|[^/]+\.mcdn\.bilivideo\.(?:com|cn|net))(?:\:\d{1,5})?/v\d/resource)',
  );

  static String getCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
  }) => _getCdnUrl(
    urls,
    defaultCDNService: defaultCDNService,
    isAudio: isAudio,
  );

  static String _getCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
    bool reportUnknown = true,
  }) {
    defaultCDNService ??= cdnService;

    if (defaultCDNService == CDNService.baseUrl) {
      return urls.first;
    }

    String? mcdnTf;
    String? mcdnUpgcxcode;

    String last = '';
    for (final url in urls) {
      last = url;
      if (_mirrorRegex.hasMatch(url)) {
        final uri = Uri.parse(url);
        if (uri.queryParameters['os'] == 'mcdn') {
          // upos-sz-mirrorcoso1.bilivideo.com os=mcdn
          mcdnUpgcxcode = url;
        } else {
          if (defaultCDNService == CDNService.backupUrl ||
              (isAudio && disableAudioCDN)) {
            return url;
          }
          return uri.replace(host: defaultCDNService.host).toString();
        }
      }

      if (_mCdnTfRegex.hasMatch(url)) {
        mcdnTf = url;
        continue;
      }

      // upos-\w*-302.* & bcache & mcdn host but upgcxcode path
      if (url.contains('/upgcxcode/')) {
        mcdnUpgcxcode = url;
        continue;
      }

      // may be deprecated
      if (url.contains('szbdyd.com')) {
        final uri = Uri.parse(url);
        final hostname =
            uri.queryParameters['xy_usource'] ?? defaultCDNService.host;
        return uri
            .replace(scheme: 'https', host: hostname, port: 443)
            .toString();
      }

      if (reportUnknown) logger.w('unknown cdn type: $url');
    }

    return mcdnUpgcxcode == null
        ? mcdnTf == null
              ? last
              : Uri(
                  scheme: 'https',
                  host: _proxyTf,
                  queryParameters: {'url': mcdnTf},
                ).toString()
        : Uri.parse(mcdnUpgcxcode)
              .replace(host: defaultCDNService.host ?? CDNService.ali.host)
              .toString();
  }

  /// 首选 CDN 优先，启用回退时按偏好尝试其它 CDN，再保留接口原始备用地址。
  static List<String> getCdnUrls(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
  }) {
    final sourceUrls = urls.where((url) => url.isNotEmpty).toList();
    if (sourceUrls.isEmpty) return const [];

    final result = <String>[
      getCdnUrl(
        sourceUrls,
        defaultCDNService: defaultCDNService,
        isAudio: isAudio,
      ),
    ];
    if (!Pref.enableMultiCdn) return result;
    if (!isAudio || !disableAudioCDN) {
      final order = Pref.cdnFallbackOrder;
      for (final service in order.isEmpty ? CDNService.values : order) {
        // 首选地址解析已报告未知来源，生成回退候选时避免逐个 CDN 重复报告。
        final url = _getCdnUrl(
          sourceUrls,
          defaultCDNService: service,
          reportUnknown: false,
        );
        if (!result.contains(url)) result.add(url);
      }
    }
    for (final url in sourceUrls) {
      if (!result.contains(url)) result.add(url);
    }
    return result;
  }

  static String getLiveCdnUrl(CodecItem e, {int index = 0}) {
    final urlInfo = e.urlInfo.getOrFirst(index);
    return (liveCdnUrl ?? urlInfo.host) + e.baseUrl + urlInfo.extra;
  }

  static List<String> getLiveCdnUrls(CodecItem item, {int index = 0}) {
    final primary = getLiveCdnUrl(item, index: index);
    final urls = <String>[primary];
    if (Pref.enableMultiCdn) {
      // 备用源使用接口原始 host，避免自定义 CDN 把所有候选改成同一地址。
      for (final info in item.urlInfo) {
        final url = info.host + item.baseUrl + info.extra;
        if (!urls.contains(url)) urls.add(url);
      }
    }
    return urls;
  }

  static VideoDecodeFormatType selectCodec(
    Iterable<String> codecs,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    if (preferCodecs.isNotEmpty) {
      int bestIndex = preferCodecs.length;
      for (final e in codecs) {
        for (int i = 0; i < bestIndex; i++) {
          if (preferCodecs[i].codes.any(e.startsWith)) {
            bestIndex = i;
            if (bestIndex == 0) {
              return preferCodecs[0];
            }
            break;
          }
        }
      }
      if (bestIndex < preferCodecs.length) {
        return preferCodecs[bestIndex];
      }
    }
    return VideoDecodeFormatType.fromString(codecs.first);
  }
}

import 'package:pili_aurora/models/common/video/cdn_type.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/models/common/video/video_decode_type.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/codec.dart';
import 'package:pili_aurora/utils/extension/iterable_ext.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

/// 对外只交付安全文案，原始解析异常留给操作所有者诊断。
class VideoSelectionException extends FormatException {
  const VideoSelectionException(
    super.message, {
    required this.cause,
    required this.stackTrace,
  });

  final Object cause;
  final StackTrace stackTrace;
}

abstract final class VideoUtils {
  static CDNService cdnService = Pref.defaultCDNService;
  static String? liveCdnUrl = Pref.liveCdnUrl;
  static bool disableAudioCDN = Pref.disableAudioCDN;

  /// 必须提供来源；缺少地址或解析失败抛出不含签名 URL 的 [FormatException]。
  static String getCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
  }) => _CdnSources(urls).select(
    defaultCDNService ?? cdnService,
    rewriteHosts: !isAudio || !disableAudioCDN,
  );

  /// 首选 CDN 优先，启用回退时按偏好尝试其它 CDN，再保留接口原始备用地址。
  static List<String> getCdnUrls(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
  }) {
    final sources = _CdnSources(urls);
    if (sources.originals.isEmpty) return const [];
    final rewriteHosts = !isAudio || !disableAudioCDN;
    final result = <String>{
      sources.select(
        defaultCDNService ?? cdnService,
        rewriteHosts: rewriteHosts,
      ),
    };
    if (!Pref.enableMultiCdn) return result.toList();
    if (rewriteHosts) {
      final order = Pref.cdnFallbackOrder;
      for (final service in order.isEmpty ? CDNService.values : order) {
        result.add(sources.select(service, reportUnknown: false));
      }
    }
    result.addAll(sources.originals);
    return result.toList();
  }

  static String getLiveCdnUrl(CodecItem e, {int index = 0}) {
    if (e.urlInfo.isEmpty) throw const FormatException('直播响应缺少播放来源');
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
    final sources = codecs.toList(growable: false);
    if (sources.isEmpty) throw const FormatException('下载响应缺少编码信息');
    if (preferCodecs.isNotEmpty) {
      int bestIndex = preferCodecs.length;
      for (final e in sources) {
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
    try {
      return VideoDecodeFormatType.fromString(sources.first);
    } on StateError catch (error, stack) {
      throw VideoSelectionException(
        '下载响应包含不支持的编码',
        cause: error,
        stackTrace: stack,
      );
    }
  }
}

/// 一次解析整组来源；签名地址索引与回退优先级共用同一份快照。
class _CdnSources {
  _CdnSources(Iterable<String> urls)
    : originals = urls.where((url) => url.trim().isNotEmpty).toList() {
    try {
      for (final url in originals) {
        if (_mirrorRegex.hasMatch(url)) {
          final uri = Uri.parse(url);
          if (uri.queryParameters['os'] != 'mcdn') {
            // 精确匹配使用接口原文，避免重新编码或借用其它主机的签名。
            _signedMirrors.putIfAbsent(uri.host, () => url);
            if (_primary == null) {
              _primary = url;
              _primaryUri = uri;
            }
            continue;
          }
        }
        // 首个可直接使用的来源确定后，只需继续收集后续主机的签名地址。
        if (_primary != null) continue;
        if (_mCdnTfRegex.hasMatch(url)) {
          _mcdnTf = url;
        } else if (url.contains('/upgcxcode/')) {
          _mcdnUpgcxcode = url;
        } else if (url.contains('szbdyd.com')) {
          _primary = url;
          _primaryUri = Uri.parse(url);
          _legacy = true;
        } else {
          _unknown.add(url);
        }
      }
    } on FormatException catch (error, stack) {
      // Uri 的异常可能包含完整签名地址，边界只交付安全的协议错误。
      throw VideoSelectionException(
        '播放来源地址格式无效',
        cause: error,
        stackTrace: stack,
      );
    }
  }

  static const _proxyTf = 'proxy-tf-all-ws.bilivideo.com';
  static final _mirrorRegex = RegExp(
    r'^https?://(?:upos-\w+-(?!302)\w+|(?:upos|proxy)-tf-[^/]+)\.(?:bilivideo|akamaized)\.(?:com|net)/upgcxcode',
  );
  static final _mCdnTfRegex = RegExp(
    r'^https?://(?:(?:(?:\d{1,3}\.){3}\d{1,3}|[^/]+\.mcdn\.bilivideo\.(?:com|cn|net))(?:\:\d{1,5})?/v\d/resource)',
  );

  final List<String> originals;
  final _signedMirrors = <String, String>{};
  final _unknown = <String>[];
  String? _primary;
  Uri? _primaryUri;
  bool _legacy = false;
  String? _mcdnTf;
  String? _mcdnUpgcxcode;

  String select(
    CDNService service, {
    bool rewriteHosts = true,
    bool reportUnknown = true,
  }) {
    if (originals.isEmpty) throw const FormatException('响应缺少播放来源');
    try {
      if (service == CDNService.baseUrl) return originals.first;
      if (_signedMirrors[service.host] case final signed? when rewriteHosts) {
        return signed;
      }
      // Akamai 不能从其它来源改写主机，缺少原始签名时保留接口首选。
      if (service == CDNService.akamai) return originals.first;
      if (reportUnknown && _unknown.isNotEmpty) {
        logger.w('发现未识别的 CDN 来源，保留接口地址（${_unknown.length} 项）');
      }
      if (_primaryUri case final uri?) {
        if (_legacy) {
          return uri
              .replace(
                scheme: 'https',
                host: uri.queryParameters['xy_usource'] ?? service.host,
                port: 443,
              )
              .toString();
        }
        if (service == CDNService.backupUrl || !rewriteHosts) return _primary!;
        return uri.replace(host: service.host).toString();
      }
      if (_mcdnUpgcxcode case final url?) {
        return Uri.parse(url)
            .replace(host: service.host ?? CDNService.ali.host)
            .toString();
      }
      if (_mcdnTf case final url?) {
        return Uri(
          scheme: 'https',
          host: _proxyTf,
          queryParameters: {'url': url},
        ).toString();
      }
      return originals.last;
    } on FormatException catch (error, stack) {
      throw VideoSelectionException(
        '播放来源地址格式无效',
        cause: error,
        stackTrace: stack,
      );
    } on ArgumentError catch (error, stack) {
      throw VideoSelectionException(
        '播放来源地址格式无效',
        cause: error,
        stackTrace: stack,
      );
    }
  }
}

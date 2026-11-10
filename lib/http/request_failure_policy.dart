import 'package:dio/dio.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/constants.dart';

final _backgroundEndpoints = {
  for (final url in [
    '${HttpString.apiBaseUrl}${Api.heartBeat}',
    '${HttpString.apiBaseUrl}${Api.historyReport}',
    '${HttpString.apiBaseUrl}${Api.mediaListHistory}',
    '${HttpString.apiBaseUrl}${Api.onlineTotal}',
    '${HttpString.apiBaseUrl}/x/v2/dm/web/seg.so',
    Api.roomEntryAction,
    Api.getCoin,
  ])
    (Uri.parse(url).host, Uri.parse(url).path),
};

/// 后台上报、可选资源和主动取消共用同一降噪规则，分别用于日志和用户提示。
bool isExpectedHttpFailure(DioException error) {
  if (error.type == DioExceptionType.cancel) return true;
  final options = error.requestOptions;
  final uri = options.uri;
  if (_backgroundEndpoints.contains((uri.host, uri.path))) return true;
  for (final domain in [
    'github.com',
    'githubusercontent.com',
    'hdslb.com',
    'biliimg.com',
  ]) {
    if (uri.host == domain || uri.host.endsWith('.$domain')) return true;
  }
  // SponsorBlock 支持用户配置的服务器，按接口路径与方法识别。
  return options.method == 'GET' &&
      uri.pathSegments.lastOrNull == 'skipSegments';
}

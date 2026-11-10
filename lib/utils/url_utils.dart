import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/navigation_request.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

abstract final class UrlUtils {
  // 302重定向路由截取
  static Future<String?> parseRedirectUrl(
    String url, [
    bool returnOri = false,
  ]) async {
    String? redirectUrl;
    try {
      final response = await Request.dio.head(
        url,
        options: Options(
          followRedirects: false,
          validateStatus: (status) {
            return status != null && 200 <= status && status < 400;
          },
          extra: {'account': AnonymousAccount()},
        ),
      );
      redirectUrl = response.headers['location']?.firstOrNull;
      if (redirectUrl != null && !redirectUrl.startsWith('http')) {
        redirectUrl = Uri.parse(url).resolve(redirectUrl).toString();
      }
    } catch (error, stackTrace) {
      final uri = Uri.tryParse(url);
      final host = uri?.host;
      logger.w(
        '解析重定向失败: ${host == null || host.isEmpty ? '<invalid url>' : host}',
        error: error.runtimeType,
        stackTrace: stackTrace,
      );
    }
    if (returnOri && redirectUrl == null) redirectUrl = url;
    if (redirectUrl != null && redirectUrl.endsWith('/')) {
      redirectUrl = redirectUrl.substring(0, redirectUrl.length - 1);
    }
    return redirectUrl;
  }

  // 匹配url路由跳转
  static Future<void> matchUrlPush(
    String pathSegment,
    String redirectUrl,
  ) async {
    final request = NavigationRequest();
    try {
      final matchRes = IdUtils.matchAvorBv(input: pathSegment);
      if (matchRes.isNotEmpty) {
        final aid = matchRes.av;
        final bvid = matchRes.bv;
        final result = await SearchHttp.pageWithDimension(aid: aid, bvid: bvid);
        if (!request.isCurrent) return;
        if (result is Error) {
          result.toast();
          return;
        }
        final res = result.dataOrNull;
        final cid = res?.cid;
        if (cid != null) {
          PageUtils.toVideoPage(
            aid: aid,
            bvid: bvid,
            cid: cid,
            dimension: res!.dimension,
            // title: res.title,
          );
        }
      } else {
        if (redirectUrl.isNotEmpty) {
          await PageUtils.handleWebview(redirectUrl);
        } else {
          SmartDialog.showToast('未找到可打开的链接');
        }
      }
    } catch (error, stackTrace) {
      logger.w('打开匹配链接失败', error: error.runtimeType, stackTrace: stackTrace);
      if (request.isCurrent) SmartDialog.showToast('链接无效或暂时无法打开');
    } finally {
      await request.close();
    }
  }
}

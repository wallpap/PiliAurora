import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/emote/data.dart';
import 'package:pili_aurora/models/remote/emote/package.dart';
import 'package:pili_aurora/models/remote/emote/setting_panel.dart';
import 'package:pili_aurora/models/remote/reply/data.dart';
import 'package:pili_aurora/models/remote/reply2reply/data.dart';
import 'package:pili_aurora/models/remote/reply_interaction/data.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/accounts/account_manager/account_mgr.dart';
import 'package:dio/dio.dart';

abstract final class ReplyHttp {
  static final Options options = Options(
    headers: {...Constants.baseHeaders, 'cookie': ''},
    extra: {'account': const NoAccount()},
  );

  static Future<LoadingState<ReplyData>> replyList({
    Account? account,
    required bool isLogin,
    required int oid,
    required String nextOffset,
    required int type,
    required int page,
    int sort = 1,
  }) {
    return Request().requestApi(
      isLogin ? Api.replyList : '${Api.replyList}/main',
      kind: ApiCallKind.query,
      decode: (body) => ReplyData.fromJson(body['data']),
      queryParameters: {
        'oid': oid,
        'type': type,
        if (isLogin) ...{
          'sort': sort,
          'pn': page,
          'ps': 20,
        } else ...{
          'pagination_str': '{"offset":"${nextOffset.replaceAll('"', '\\"')}"}',
          'mode': sort + 2, // 2：按时间排序；3：按热度排序
        },
      },
      options: isLogin
          ? Options(
              extra: {
                'account':
                    account ?? AccountManager.resolveAccount(Api.replyList),
              },
            )
          : options,
    );
  }

  static Future<LoadingState<ReplyReplyData>> replyReplyList({
    Account? account,
    required bool isLogin,
    required int oid,
    required int root,
    required int pageNum,
    required int type,
  }) {
    account ??= AccountManager.resolveAccount(Api.replyReplyList);
    return Request().requestApi(
      Api.replyReplyList,
      kind: ApiCallKind.query,
      decode: (body) => ReplyReplyData.fromJson(body['data']),
      queryParameters: {
        'oid': oid,
        'root': root,
        'pn': pageNum,
        'type': type,
        'sort': 1,
        if (isLogin) 'csrf': account.csrf,
      },
      options: isLogin ? Options(extra: {'account': account}) : options,
    );
  }

  static Future<LoadingState<void>> hateReply({
    Account? account,
    required int type,
    required int action,
    required int oid,
    required int rpid,
  }) {
    account ??= Accounts.main;
    return Request().requestApi<void>(
      Api.hateReply,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'type': type,
        'oid': oid,
        'rpid': rpid,
        'action': action,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  // 评论点赞
  static Future<LoadingState<void>> likeReply({
    Account? account,
    required int type,
    required int oid,
    required int rpid,
    required int action,
  }) {
    account ??= Accounts.main;
    return Request().requestApi<void>(
      Api.likeReply,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'type': type,
        'oid': oid,
        'rpid': rpid,
        'action': action,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<List<Package>?>> getEmoteList({
    String? business,
  }) {
    return Request().requestApi(
      Api.myEmote,
      kind: ApiCallKind.query,
      decode: (body) => EmoteModelData.fromJson(body['data']).packages,
      queryParameters: {
        'business': business ?? 'reply',
        'web_location': '333.1245',
      },
    );
  }

  static Future<LoadingState<EmoteSettingPanel>> getEmoteSettingPanel({
    Account? account,
    String business = 'reply',
  }) {
    return Request().requestApi(
      Api.emoteSettingPanel,
      kind: ApiCallKind.query,
      decode: (body) => EmoteSettingPanel.fromJson(body['data']),
      queryParameters: {'business': business},
      options: Options(extra: {'account': account ?? Accounts.main}),
    );
  }

  static Future<LoadingState<List<Package>>> getMyEmotePackages({
    Account? account,
    required int type,
  }) async {
    account ??= Accounts.main;
    final packages = <Package>[];
    final ids = <int>{};
    for (var page = 1; page <= 100; page++) {
      final result = await Request().requestApi(
        Api.myEmotePackages,
        kind: ApiCallKind.query,
        decode: (body) {
          final data = body['data'] as Map<String, dynamic>;
          final total = data['total'] as int;
          if (total < 0) throw const FormatException('表情包总数无效');
          final items = (data['packages'] as List? ?? [])
              .map((item) => Package.fromJson(item as Map<String, dynamic>))
              .toList();
          if (items.any((item) => (item.id ?? 0) <= 0)) {
            throw const FormatException('表情包缺少有效 ID');
          }
          return (items: items, total: total);
        },
        queryParameters: {
          'business': 'reply',
          'type': type,
          'pn': page,
          'ps': 100,
        },
        options: Options(extra: {'account': account}),
      );
      if (result is Error) return result;
      final (:items, :total) = result.data;
      if (items.isEmpty) {
        return packages.length >= total
            ? Success(packages)
            : const Error('表情包列表未能完整加载，请刷新重试');
      }
      final fresh = items.where((item) => ids.add(item.id!)).toList();
      if (fresh.isEmpty) return const Error('表情包列表未能继续加载，请刷新重试');
      packages.addAll(fresh);
      if (packages.length >= total) {
        return Success(packages);
      }
    }
    return const Error('表情包列表超出加载上限，请稍后重试');
  }

  static Future<LoadingState<Package>> getEmotePackageDetail({
    Account? account,
    required int packageId,
    String business = 'reply',
  }) {
    return Request().requestApi(
      Api.emotePackageDetail,
      kind: ApiCallKind.query,
      decode: (body) {
        final package = Package.fromJson(body['data']['package']);
        if (package.id != packageId) throw const FormatException('表情包 ID 不匹配');
        return package;
      },
      queryParameters: {'id': packageId, 'business': business},
      options: Options(extra: {'account': account ?? Accounts.main}),
    );
  }

  static Future<LoadingState<void>> addEmotePackage({
    Account? account,
    required int packageId,
    String business = 'reply',
  }) => _changeEmotePackage(
    Api.addEmotePackage,
    account: account,
    packageId: packageId,
    business: business,
  );

  static Future<LoadingState<void>> removeEmotePackage({
    Account? account,
    required int packageId,
    String business = 'reply',
  }) => _changeEmotePackage(
    Api.removeEmotePackage,
    account: account,
    packageId: packageId,
    business: business,
  );

  static Future<LoadingState<void>> _changeEmotePackage(
    String api, {
    Account? account,
    required int packageId,
    required String business,
  }) {
    account ??= Accounts.main;
    return Request().requestApi<void>(
      api,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'package_id': packageId,
        'business': business,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<void>> replyTop({
    Account? account,
    required Object oid,
    required Object type,
    required Object rpid,
    required bool isUpTop,
  }) {
    account ??= Accounts.main;
    return Request().requestApi<void>(
      Api.replyTop,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'oid': oid,
        'type': type,
        'rpid': rpid,
        'action': isUpTop ? 0 : 1,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<void>> report({
    Account? account,
    required Object rpid,
    required Object oid,
    required int reasonType,
    bool banUid = true,
    String? reasonDesc,
  }) {
    account ??= Accounts.main;
    return Request().requestApi<void>(
      Api.replyReport,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'add_blacklist': banUid,
        'csrf': account.csrf,
        'gaia_source': 'main_h5',
        'oid': oid,
        'platform': 'android',
        'reason': reasonType,
        'rpid': rpid,
        'scene': 'main',
        'type': 1,
        'content': ?reasonDesc,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<ReplyInteractData>> replyInteraction({
    Account? account,
    required Object oid,
    required Object type,
  }) {
    return Request().requestApi(
      Api.replyInteraction,
      kind: ApiCallKind.query,
      decode: (body) => ReplyInteractData.fromJson(body['data']),
      queryParameters: {
        'oid': oid,
        'type': type,
        'web_location': 333.1369,
      },
      options: Options(extra: {'account': account ?? Accounts.main}),
    );
  }

  static Future<LoadingState<String?>> replySubjectModify({
    Account? account,
    required int oid,
    required int type,
    required int action,
  }) {
    account ??= Accounts.main;
    return Request().requestApi(
      Api.replySubjectModify,
      kind: ApiCallKind.mutation,
      decode: (body) => body['data']?['action_toast'] as String?,
      data: {
        'oid': oid,
        'type': type,
        'action': action,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }
}

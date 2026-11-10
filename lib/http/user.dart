import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/user/info.dart';
import 'package:pili_aurora/models/user/stat.dart';
import 'package:pili_aurora/models/remote/coin_log/data.dart';
import 'package:pili_aurora/models/remote/follow/data.dart';
import 'package:pili_aurora/models/remote/history/data.dart';
import 'package:pili_aurora/models/remote/later/data.dart';
import 'package:pili_aurora/models/remote/login_log/data.dart';
import 'package:pili_aurora/models/remote/media_list/data.dart';
import 'package:pili_aurora/models/remote/relation/data.dart';
import 'package:pili_aurora/models/remote/space_setting/data.dart';
import 'package:pili_aurora/models/remote/sub/sub/data.dart';
import 'package:pili_aurora/models/remote/user_real_name/data.dart';
import 'package:pili_aurora/models/remote/video/video_tag/data.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/app_sign.dart';
import 'package:pili_aurora/utils/wbi_sign.dart';
import 'package:dio/dio.dart';

abstract final class UserHttp {
  static Future<LoadingState<UserInfoData>> userInfo({Account? account}) async {
    return await Request().requestApi(
      Api.userInfo,
      kind: ApiCallKind.query,
      decode: (body) => UserInfoData.fromJson(body['data']),
      options: Options(extra: {'account': account ?? Accounts.main}),
    );
  }

  static Future<LoadingState<UserStat>> userStatOwner({
    Account? account,
  }) async {
    return await Request().requestApi(
      Api.userStatOwner,
      kind: ApiCallKind.query,
      decode: (body) => UserStat.fromJson(body['data']),
      options: Options(extra: {'account': account ?? Accounts.main}),
    );
  }

  // 稍后再看
  static Future<LoadingState<LaterData>> seeYouLater({
    required int page,
    int viewed = 0,
    String keyword = '',
    bool asc = false,
    Account? account,
  }) async {
    account ??= Accounts.main;
    try {
      return await Request().requestApi(
        Api.seeYouLater,
        kind: ApiCallKind.query,
        decode: (body) => LaterData.fromJson(body['data']),
        options: Options(extra: {'account': account}),
        queryParameters: await WbiSign.makSign({
          'pn': page,
          'ps': 20,
          'viewed': viewed,
          'key': keyword,
          'asc': asc,
          'need_split': true,
          'web_location': 333.881,
        }),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  // 观看历史
  static Future<LoadingState<HistoryData>> historyList({
    required String type,
    int? max,
    int? viewAt,
    Account? account,
  }) async {
    return await Request().requestApi(
      Api.historyList,
      kind: ApiCallKind.query,
      decode: (body) => HistoryData.fromJson(body['data']),
      queryParameters: {
        'type': type,
        'ps': 20,
        'max': max ?? 0,
        'view_at': viewAt ?? 0,
      },
      options: Options(extra: {'account': account ?? Accounts.history}),
    );
  }

  // 暂停观看历史
  static Future<LoadingState<void>> pauseHistory(
    bool switchStatus, {
    Account? account,
  }) async {
    // 暂停switchStatus传true 否则false
    account ??= Accounts.history;
    return await Request().requestApi<void>(
      Api.pauseHistory,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'switch': switchStatus,
        'jsonp': 'jsonp',
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  // 观看历史暂停状态
  static Future<LoadingState<bool>> historyStatus({Account? account}) async {
    return await Request().requestApi(
      Api.historyStatus,
      kind: ApiCallKind.query,
      decode: (body) => body['data'] as bool,
      options: Options(extra: {'account': account ?? Accounts.history}),
    );
  }

  // 清空历史记录
  static Future<LoadingState<void>> clearHistory({Account? account}) async {
    account ??= Accounts.history;
    return await Request().requestApi<void>(
      Api.clearHistory,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'jsonp': 'jsonp',
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  // 稍后再看
  static Future<LoadingState<void>> toViewLater({
    String? bvid,
    Object? aid,
    Account? account,
  }) async {
    if (aid == null && (bvid == null || bvid.trim().isEmpty)) {
      return const Error('视频标识无效');
    }
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.toViewLater,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'aid': ?aid,
        'bvid': ?bvid,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  // 移除已观看
  static Future<LoadingState<void>> toViewDel({
    required String aids,
    Account? account,
  }) async {
    if (aids.trim().isEmpty) return const Error('请选择要移除的视频');
    account ??= Accounts.main;
    final Map<String, dynamic> params = {
      'csrf': account.csrf,
      'resources': aids,
    };
    return await Request().requestApi<void>(
      Api.toViewDel,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: params,
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  // 清空稍后再看 // clean_type: null->all, 1->invalid, 2->viewed
  static Future<LoadingState<void>> toViewClear({
    int? cleanType,
    Account? account,
  }) async {
    if (cleanType != null && cleanType != 1 && cleanType != 2) {
      return const Error('无效的清空类型');
    }
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.toViewClear,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'clean_type': ?cleanType,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  // 删除历史记录
  static Future<LoadingState<void>> delHistory(
    String kid, {
    Account? account,
  }) async {
    if (kid.trim().isEmpty) return const Error('请选择要删除的记录');
    account ??= Accounts.history;
    return await Request().requestApi<void>(
      Api.delHistory,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'kid': kid,
        'jsonp': 'jsonp',
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<RelationData>> userRelation(
    int mid, {
    Account? account,
  }) async {
    return await Request().requestApi(
      Api.relation,
      kind: ApiCallKind.query,
      decode: (body) => RelationData.fromJson(body['data']),
      options: Options(extra: {'account': account ?? Accounts.main}),
      queryParameters: {
        'fid': mid,
      },
    );
  }

  // 搜索历史记录
  static Future<LoadingState<HistoryData>> searchHistory({
    required int pn,
    required String keyword,
    Account? account,
  }) async {
    return await Request().requestApi(
      Api.searchHistory,
      kind: ApiCallKind.query,
      decode: (body) => HistoryData.fromJson(body['data']),
      queryParameters: {
        'pn': pn,
        'keyword': keyword,
        'business': 'all',
      },
      options: Options(extra: {'account': account ?? Accounts.history}),
    );
  }

  // 我的订阅
  static Future<LoadingState<SubData>> userSubFolder({
    Account? account,
    required int mid,
    required int pn,
    required int ps,
  }) async {
    return await Request().requestApi(
      Api.userSubFolder,
      kind: ApiCallKind.query,
      options: Options(extra: {'account': account ?? Accounts.main}),
      decode: (body) => SubData.fromJson(body['data']),
      queryParameters: {
        'up_mid': mid,
        'ps': ps,
        'pn': pn,
        'platform': 'web',
      },
    );
  }

  static Future<LoadingState<List<VideoTagItem>?>> videoTags({
    required String bvid,
    Object? cid,
  }) async {
    return await Request().requestApi(
      Api.videoTags,
      kind: ApiCallKind.query,
      decode: (body) => (body['data'] as List?)
          ?.map((e) => VideoTagItem.fromJson(e))
          .toList(),
      queryParameters: {'bvid': bvid, 'cid': ?cid},
    );
  }

  // 稍后再看列表
  static Future<LoadingState<MediaListData>> getMediaList({
    required Object type,
    required Object bizId,
    required int ps,
    dynamic oid,
    int? otype,
    bool withCurrent = false,
    bool desc = true,
    dynamic sortField = 1,
    bool direction = false,
  }) async {
    return await Request().requestApi(
      Api.mediaList,
      kind: ApiCallKind.query,
      decode: (body) => MediaListData.fromJson(body['data']),
      queryParameters: {
        'mobi_app': 'web',
        'type': type,
        'biz_id': bizId,
        'oid': ?oid,
        'otype': ?otype, // ugc:2 // pgc: 24
        'ps': ps,
        'direction': direction,
        'desc': desc,
        'sort_field': sortField,
        'tid': 0,
        'with_current': withCurrent,
      },
    );
  }

  static Future<LoadingState<num?>> getCoin({Account? account}) async {
    return await Request().requestApi(
      Api.getCoin,
      kind: ApiCallKind.query,
      decode: (body) =>
          (body['data'] as Map<String, dynamic>?)?['money'] as num?,
      options: Options(extra: {'account': account ?? Accounts.main}),
    );
  }

  static Future<LoadingState<void>> dynamicReport({
    required Object mid,
    required Object dynId,
    required int reasonType,
    String? reasonDesc,
    Account? account,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.dynamicReport,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      queryParameters: {
        'csrf': account.csrf,
      },
      data: {
        "accused_uid": mid,
        "dynamic_id": dynId,
        "reason_type": reasonType,
        "reason_desc": reasonDesc,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<SpaceSettingData>> spaceSetting({
    required Account account,
  }) async {
    return await Request().requestApi(
      Api.spaceSetting,
      kind: ApiCallKind.query,
      decode: (body) => SpaceSettingData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'mid': account.mid,
      },
    );
  }

  static Future<LoadingState<void>> spaceSettingMod(
    Map<String, dynamic> data, {
    required Account account,
  }) async {
    return await Request().requestApi<void>(
      Api.spaceSettingMod,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      queryParameters: {
        'csrf': account.csrf,
      },
      data: data,
      options: Options(
        extra: {'account': account, 'noRetry': true},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<void>> vipExpAdd({Account? account}) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.vipExpAdd,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      options: Options(extra: {'account': account}),
      queryParameters: {
        'mid': account.mid,
        'csrf': account.csrf,
      },
    );
  }

  static Future<LoadingState<CoinLogData>> coinLog({
    required Account account,
  }) async {
    return await Request().requestApi(
      Api.coinLog,
      kind: ApiCallKind.query,
      decode: (body) => CoinLogData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'jsonp': 'jsonp',
        'web_location': '333.33',
      },
    );
  }

  static Future<LoadingState<LoginLogData>> loginLog({
    required Account account,
  }) async {
    return await Request().requestApi(
      Api.loginLog,
      kind: ApiCallKind.query,
      decode: (body) => LoginLogData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'jsonp': 'jsonp',
        'web_location': '333.33',
      },
    );
  }

  static Future<LoadingState<CoinLogData>> expLog({
    required Account account,
  }) async {
    return await Request().requestApi(
      Api.expLog,
      kind: ApiCallKind.query,
      decode: (body) => CoinLogData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'jsonp': 'jsonp',
        'web_location': '333.33',
      },
    );
  }

  static Future<LoadingState<UserRealNameData>> getUserRealName(
    Object mid, {
    Account? account,
  }) async {
    account ??= Accounts.main;
    final params = {
      'access_key': ?account.accessKey,
      'up_mid': mid,
    };
    AppSign.appSign(params);
    return await Request().requestApi(
      Api.userRealName,
      kind: ApiCallKind.query,
      decode: (body) => UserRealNameData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: params,
    );
  }

  static Future<LoadingState<FollowData>> followedUp({
    required Object mid,
    required Account account,
    required int pn,
  }) async {
    return await Request().requestApi(
      Api.followedUp,
      kind: ApiCallKind.query,
      decode: (body) => FollowData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'csrf': account.csrf,
        'pn': pn,
        'vmid': mid,
        'web_location': 333.789,
        'x-bili-device-req-json':
            '{"platform":"web","device":"pc","spmid":"333.789"}',
      },
    );
  }

  static Future<LoadingState<FollowData>> sameFollowing({
    required Object mid,
    required Account account,
    required int pn,
  }) async {
    return await Request().requestApi(
      Api.sameFollowing,
      kind: ApiCallKind.query,
      decode: (body) => FollowData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'csrf': account.csrf,
        'pn': pn,
        'vmid': mid,
        'web_location': 333.789,
        'x-bili-device-req-json':
            '{"platform":"web","device":"pc","spmid":"333.789"}',
      },
    );
  }

  static Future<LoadingState<void>> spaceReserve({
    required Object sid,
    required bool isFollow,
    Account? account,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      isFollow ? Api.spaceReserveCancel : Api.spaceReserve,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'sid': sid,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }
}

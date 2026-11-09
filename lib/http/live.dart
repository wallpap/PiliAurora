import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/login.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/live/live_contribution_rank_type.dart';
import 'package:pili_aurora/models/common/live/live_search_type.dart';
import 'package:pili_aurora/models/remote/live/live_area_list/area_item.dart';
import 'package:pili_aurora/models/remote/live/live_area_list/area_list.dart';
import 'package:pili_aurora/models/remote/live/live_contribution_rank/data.dart';
import 'package:pili_aurora/models/remote/live/live_danmaku/danmaku_msg.dart';
import 'package:pili_aurora/models/remote/live/live_dm_block/data.dart';
import 'package:pili_aurora/models/remote/live/live_dm_block/shield_info.dart';
import 'package:pili_aurora/models/remote/live/live_dm_block/shield_user_list.dart';
import 'package:pili_aurora/models/remote/live/live_dm_info/data.dart';
import 'package:pili_aurora/models/remote/live/live_emote/data.dart';
import 'package:pili_aurora/models/remote/live/live_emote/datum.dart';
import 'package:pili_aurora/models/remote/live/live_feed_index/data.dart';
import 'package:pili_aurora/models/remote/live/live_follow/data.dart';
import 'package:pili_aurora/models/remote/live/live_guard_top_list/data.dart';
import 'package:pili_aurora/models/remote/live/live_medal_wall/data.dart';
import 'package:pili_aurora/models/remote/live/live_room_info_h5/data.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/data.dart';
import 'package:pili_aurora/models/remote/live/live_search/data.dart';
import 'package:pili_aurora/models/remote/live/live_second_list/data.dart';
import 'package:pili_aurora/models/remote/live/live_superchat/data.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/app_sign.dart';
import 'package:pili_aurora/utils/wbi_sign.dart';
import 'package:dio/dio.dart';

abstract final class LiveHttp {
  static Account get recommend => Accounts.get(AccountType.recommend);

  static Future<LoadingState<void>> sendLiveMsg({
    required Object roomId,
    required Object msg,
    Object? dmType,
    Object? emoticonOptions,
    int replyMid = 0,
    String replayDmid = '',
    Account? account,
  }) async {
    account ??= Accounts.main;
    final csrf = account.csrf;
    try {
      return await Request().requestApi(
        Api.sendLiveMsg,
        kind: ApiCallKind.mutation,
        decode: (_) {},
        options: Options(extra: {'account': account}),
        queryParameters: await WbiSign.makSign({'web_location': 444.8}),
        data: FormData.fromMap({
          'bubble': 0,
          'msg': msg,
          'color': 16777215,
          'mode': 1,
          'dm_type': ?dmType,
          if (emoticonOptions != null)
            'emoticonOptions': emoticonOptions
          else ...{
            'room_type': 0,
            'jumpfrom': 0,
            'reply_mid': replyMid,
            'reply_attr': 0,
            'replay_dmid': replayDmid,
            'statistics': '{"appId":100,"platform":5}',
            'reply_type': 0,
            'reply_uname': '',
          },
          'fontsize': 25,
          'rnd': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'roomid': roomId,
          'csrf': csrf,
          'csrf_token': csrf,
        }),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<RoomPlayInfoData>> liveRoomInfo({
    required Object roomId,
    Object? qn,
    bool onlyAudio = false,
    CancelToken? cancelToken,
  }) async {
    final account = Accounts.heartbeat;
    try {
      return await Request().requestApi(
        Api.liveRoomInfo,
        kind: ApiCallKind.query,
        decode: (body) => RoomPlayInfoData.fromJson(body['data']),
        cancelToken: cancelToken,
        options: Options(extra: {'account': account}),
        queryParameters: await WbiSign.makSign({
          'room_id': roomId,
          'protocol': '0,1',
          'format': '0,1,2',
          'codec': '0,1,2',
          'qn': ?qn,
          'platform': 'web',
          'ptype': 8,
          'dolby': 5,
          'panorama': 1,
          if (onlyAudio) 'only_audio': 1,
          'web_location': 444.8,
        }),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<RoomInfoH5Data>> liveRoomInfoH5({
    required Object roomId,
  }) async {
    return await Request().requestApi(
      Api.liveRoomInfoH5,
      kind: ApiCallKind.query,
      decode: (body) => RoomInfoH5Data.fromJson(body['data']),
      queryParameters: {'room_id': roomId},
    );
  }

  static Future<LoadingState<List<DanmakuMsg>?>> liveRoomDmPrefetch({
    required Object roomId,
  }) async {
    return await Request().requestApi(
      Api.liveRoomDmPrefetch,
      kind: ApiCallKind.query,
      decode: (body) => (body['data']?['room'] as List?)
          ?.map((e) => DanmakuMsg.fromPrefetch(e))
          .toList(),
      queryParameters: {'roomid': roomId},
      options: Options(
        headers: {
          'referer': 'https://live.bilibili.com/$roomId',
          'user-agent': BrowserUa.pc,
        },
      ),
    );
  }

  static Future<LoadingState<LiveDmInfoData>> liveRoomGetDanmakuToken({
    required Object roomId,
  }) async {
    final account = Accounts.heartbeat;
    try {
      return await Request().requestApi(
        Api.liveRoomDmToken,
        kind: ApiCallKind.query,
        decode: (body) => LiveDmInfoData.fromJson(body['data']),
        options: Options(extra: {'account': account}),
        queryParameters: await WbiSign.makSign({
          'id': roomId,
          'web_location': 444.8,
        }),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<List<LiveEmoteDatum>?>> getLiveEmoticons({
    required int roomId,
  }) async {
    return await Request().requestApi(
      Api.getLiveEmoticons,
      kind: ApiCallKind.query,
      decode: (body) => LiveEmoteData.fromJson(body['data']).data,
      queryParameters: {
        'platform': 'pc',
        'room_id': roomId,
      },
    );
  }

  static Future<LoadingState<LiveIndexData>> liveFeedIndex({
    required int pn,
    bool moduleSelect = false,
  }) async {
    final account = recommend;
    final params = {
      'access_key': ?account.accessKey,
      'channel': 'master',
      'actionKey': 'appkey',
      'build': 8430300,
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'device': 'android',
      'device_name': 'android',
      'device_type': 0,
      'fnval': 912,
      'disable_rcmd': 0,
      'https_url_req': 1,
      if (moduleSelect) 'module_select': 1,
      'mobi_app': 'android',
      'network': 'wifi',
      'page': pn,
      'platform': 'android',
      if (account.isLogin) 'relation_page': 1,
      's_locale': 'zh_CN',
      'scale': 2,
      'statistics': Constants.statisticsApp,
    };
    AppSign.appSign(params);
    return await Request().requestApi(
      Api.liveFeedIndex,
      kind: ApiCallKind.query,
      decode: (body) => LiveIndexData.fromJson(body['data']),
      queryParameters: params,
      options: Options(
        extra: {'account': account},
        headers: {
          'buvid': LoginHttp.buvid,
          'fp_local': '1111111111111111111111111111111111111111111111111111111111111111',
          'fp_remote': '1111111111111111111111111111111111111111111111111111111111111111',
          'session_id': '11111111',
          'env': 'prod',
          'app-key': 'android',
          'User-Agent': Constants.userAgentApp,
          'x-bili-trace-id': Constants.traceId,
          'x-bili-aurora-eid': '',
          'x-bili-aurora-zone': '',
          'bili-http-engine': 'cronet',
        },
      ),
    );
  }

  static Future<LoadingState<LiveFollowData>> liveFollow(
    int page, {
    required Account account,
  }) async {
    return await Request().requestApi(
      Api.liveFollow,
      kind: ApiCallKind.query,
      decode: (body) => LiveFollowData.fromJson(body['data']),
      queryParameters: {
        'page': page,
        'page_size': 9,
        'ignoreRecord': 1,
        'hit_ab': true,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<LiveSecondData>> liveSecondList({
    required int pn,
    required Object? areaId,
    required Object? parentAreaId,
    String? sortType,
  }) async {
    final account = recommend;
    final params = {
      'access_key': ?account.accessKey,
      'actionKey': 'appkey',
      'channel': 'master',
      'area_id': ?areaId,
      'parent_area_id': ?parentAreaId,
      'build': 8430300,
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'device': 'android',
      'device_name': 'android',
      'device_type': 0,
      'fnval': 912,
      'disable_rcmd': 0,
      'https_url_req': 1,
      'mobi_app': 'android',
      'module_select': 0,
      'network': 'wifi',
      'page': pn,
      'page_size': 20,
      'platform': 'android',
      'qn': 0,
      'sort_type': ?sortType,
      'tag_version': 1,
      's_locale': 'zh_CN',
      'scale': 2,
      'statistics': Constants.statisticsApp,
    };
    AppSign.appSign(params);
    return await Request().requestApi(
      Api.liveSecondList,
      kind: ApiCallKind.query,
      decode: (body) => LiveSecondData.fromJson(body['data']),
      queryParameters: params,
      options: Options(
        extra: {'account': account},
        headers: {
          'buvid': LoginHttp.buvid,
          'fp_local': '1111111111111111111111111111111111111111111111111111111111111111',
          'fp_remote': '1111111111111111111111111111111111111111111111111111111111111111',
          'session_id': '11111111',
          'env': 'prod',
          'app-key': 'android',
          'User-Agent': Constants.userAgentApp,
          'x-bili-trace-id': Constants.traceId,
          'x-bili-aurora-eid': '',
          'x-bili-aurora-zone': '',
          'bili-http-engine': 'cronet',
        },
      ),
    );
  }

  static Future<LoadingState<List<AreaList>?>> liveAreaList({
    Account? account,
  }) async {
    account ??= recommend;
    final params = {
      'access_key': ?account.accessKey,
      'actionKey': 'appkey',
      'build': 8430300,
      'channel': 'master',
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'device': 'android',
      'disable_rcmd': 0,
      'mobi_app': 'android',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statisticsApp,
    };
    AppSign.appSign(params);
    return await Request().requestApi(
      Api.liveAreaList,
      kind: ApiCallKind.query,
      decode: (body) => (body['data']?['list'] as List?)
          ?.map((e) => AreaList.fromJson(e))
          .toList(),
      options: Options(extra: {'account': account}),
      queryParameters: params,
    );
  }

  static Future<LoadingState<List<AreaItem>>> getLiveFavTag({
    required Account account,
  }) async {
    final params = {
      'access_key': ?account.accessKey,
      'actionKey': 'appkey',
      'build': 8430300,
      'channel': 'master',
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'device': 'android',
      'disable_rcmd': 0,
      'mobi_app': 'android',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statisticsApp,
    };
    AppSign.appSign(params);
    return await Request().requestApi(
      Api.getLiveFavTag,
      kind: ApiCallKind.query,
      decode: (body) =>
          (body['data']?['tags'] as List?)
              ?.map((e) => AreaItem.fromJson(e))
              .toList() ??
          <AreaItem>[],
      options: Options(extra: {'account': account}),
      queryParameters: params,
    );
  }

  static Future<LoadingState<void>> setLiveFavTag({
    required String ids,
    required Account account,
  }) async {
    final data = {
      'tags': ids,
      'access_key': ?account.accessKey,
      'actionKey': 'appkey',
      'build': 8430300,
      'channel': 'master',
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'device': 'android',
      'disable_rcmd': 0,
      'mobi_app': 'android',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statisticsApp,
    };
    AppSign.appSign(data);
    return await Request().requestApi(
      Api.setLiveFavTag,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
  }

  static Future<LoadingState<List<AreaItem>?>> liveRoomAreaList({
    required Object parentid,
  }) async {
    final account = recommend;
    final params = {
      'access_key': ?account.accessKey,
      'actionKey': 'appkey',
      'build': 8430300,
      'channel': 'master',
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'device': 'android',
      'disable_rcmd': 0,
      'need_entrance': 1,
      'parent_id': parentid,
      'source_id': 2,
      'mobi_app': 'android',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statisticsApp,
    };
    AppSign.appSign(params);
    return await Request().requestApi(
      Api.liveRoomAreaList,
      kind: ApiCallKind.query,
      decode: (body) =>
          (body['data'] as List?)?.map((e) => AreaItem.fromJson(e)).toList(),
      options: Options(extra: {'account': account}),
      queryParameters: params,
    );
  }

  static Future<LoadingState<LiveSearchData>> liveSearch({
    required Account account,
    required int page,
    required String keyword,
    required LiveSearchType type,
  }) async {
    final params = {
      'access_key': ?account.accessKey,
      'actionKey': 'appkey',
      'build': 8430300,
      'channel': 'master',
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'device': 'android',
      'page': page,
      'pagesize': 30,
      'keyword': keyword,
      'disable_rcmd': 0,
      'mobi_app': 'android',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statisticsApp,
      'type': type.name,
    };
    AppSign.appSign(params);
    return await Request().requestApi(
      Api.liveSearch,
      kind: ApiCallKind.query,
      decode: (body) => LiveSearchData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: params,
    );
  }

  static Future<LoadingState<ShieldInfo?>> getLiveInfoByUser(
    Object roomId, {
    Account? account,
  }) async {
    account ??= Accounts.main;
    try {
      return await Request().requestApi(
        Api.getLiveInfoByUser,
        kind: ApiCallKind.query,
        decode: (body) => LiveDmBlockData.fromJson(body['data']).shieldInfo,
        options: Options(extra: {'account': account}),
        queryParameters: await WbiSign.makSign({
          'room_id': roomId,
          'from': 0,
          'not_mock_enter_effect': 1,
          'web_location': 444.8,
        }),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<void>> liveSetSilent({
    required String type,
    required int level,
  }) async {
    final account = Accounts.main;
    final csrf = account.csrf;
    return await Request().requestApi(
      Api.liveSetSilent,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'type': type,
        'level': level,
        'csrf': csrf,
        'csrf_token': csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
  }

  static Future<LoadingState<void>> addShieldKeyword({
    required String keyword,
    required Account account,
  }) async {
    final csrf = account.csrf;
    return await Request().requestApi(
      Api.addShieldKeyword,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'keyword': keyword,
        'csrf': csrf,
        'csrf_token': csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
  }

  static Future<LoadingState<void>> delShieldKeyword({
    required String keyword,
    required Account account,
  }) async {
    final csrf = account.csrf;
    return await Request().requestApi(
      Api.delShieldKeyword,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'keyword': keyword,
        'csrf': csrf,
        'csrf_token': csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
  }

  static Future<LoadingState<ShieldUserList?>> liveShieldUser({
    required Object uid,
    required Object roomid,
    required int type,
    Account? account,
  }) async {
    account ??= Accounts.main;
    final csrf = account.csrf;
    return await Request().requestApi(
      Api.liveShieldUser,
      kind: ApiCallKind.mutation,
      decode: (body) {
        if (type == 0) return null;
        final user = ShieldUserList.fromJson(body['data']);
        if (user.uid <= 0 || user.uid.toString() != uid.toString()) {
          throw const FormatException('屏蔽用户响应与目标不符');
        }
        return user;
      },
      data: {
        'uid': uid,
        'roomid': roomid,
        'type': type,
        'csrf': csrf,
        'csrf_token': csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
  }

  static Future<LoadingState<void>> liveLikeReport({
    required int clickTime,
    required Object roomId,
    required Object uid,
    Object? anchorId,
  }) async {
    final account = Accounts.heartbeat;
    try {
      return await Request().requestApi(
        Api.liveLikeReport,
        kind: ApiCallKind.mutation,
        decode: (_) {},
        data: await WbiSign.makSign({
          'click_time': clickTime,
          'room_id': roomId,
          'uid': uid,
          'anchor_id': ?anchorId,
          'web_location': 444.8,
          'csrf': account.csrf,
        }),
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          extra: {'account': account},
        ),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  static Future<LoadingState<SuperChatData>> superChatMsg(
    int roomId,
  ) async {
    return await Request().requestApi(
      Api.superChatMsg,
      kind: ApiCallKind.query,
      decode: (body) => SuperChatData.fromJson(body['data'], roomId),
      queryParameters: {
        'room_id': roomId,
      },
    );
  }

  static Future<LoadingState<void>> liveDmReport({
    required int roomId,
    required Object mid,
    required String msg,
    required String reason,
    required int reasonId,
    required int dmType,
    required Object idStr,
    required Object ts,
    required Object sign,
  }) async {
    final account = Accounts.main;
    final csrf = account.csrf;
    final data = {
      'id': 0,
      'roomid': roomId,
      'tuid': mid,
      'msg': msg,
      'reason': reason,
      'ts': ts,
      'sign': sign,
      'reason_id': reasonId,
      'token': '',
      'dm_type': dmType,
      'id_str': idStr,
      'csrf_token': csrf,
      'csrf': csrf,
      'visit_id': '',
    };
    return await Request().requestApi(
      Api.liveDmReport,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
  }

  static Future<LoadingState<LiveContributionRankData>> liveContributionRank({
    required Object ruid,
    required Object roomId,
    required int page,
    required LiveContributionRankType type,
  }) async {
    final account = Accounts.main;
    try {
      return await Request().requestApi(
        Api.liveContributionRank,
        kind: ApiCallKind.query,
        decode: (body) => LiveContributionRankData.fromJson(body['data']),
        options: Options(extra: {'account': account}),
        queryParameters: await WbiSign.makSign({
          'ruid': ruid,
          'room_id': roomId,
          'page': page,
          'page_size': 100,
          'type': type.name,
          'switch': type.sw1tch,
          'platform': 'web',
          'web_location': 444.8,
        }),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<LiveGuardTopListData>> liveGuardTopList({
    required Object roomId,
    required Object ruid,
  }) async {
    return await Request().requestApi(
      Api.liveGuardTopList,
      kind: ApiCallKind.query,
      decode: (body) => LiveGuardTopListData.fromJson(body['data']),
      queryParameters: {
        'roomid': roomId,
        'ruid': ruid,
        'page': 1,
        'page_size': 10,
      },
    );
  }

  static Future<LoadingState<void>> superChatReport({
    required int id,
    required Object roomId,
    required Object uid,
    required String msg,
    required String reason,
    required int ts,
    required String token,
  }) async {
    final account = Accounts.main;
    final csrf = account.csrf;
    return await Request().requestApi(
      Api.superChatReport,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'id': id,
        'roomid': roomId,
        'uid': uid,
        'msg': msg,
        'reason': reason,
        'ts': ts,
        'sign': '',
        'reason_id': reason,
        'token': token,
        'id_str': id.toString(),
        'csrf_token': csrf,
        'csrf': csrf,
        'visit_id': '',
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
  }

  static Future<LoadingState<MedalWallData>> liveMedalWall({
    required Object mid,
  }) async {
    return await Request().requestApi(
      Api.liveMedalWall,
      kind: ApiCallKind.query,
      decode: (body) => MedalWallData.fromJson(body['data']),
      queryParameters: {'target_id': mid},
    );
  }

  static Future<LoadingState<void>> liveFeedback(
    Object roomId,
    Object id,
    String type, {
    int page = 1,
  }) async {
    final account = recommend;
    final params = {
      'access_key': ?account.accessKey,
      'actionKey': 'appkey',
      'build': 8430300,
      'channel': 'master',
      'c_locale': 'zh_CN',
      'device': 'android',
      'disable_rcmd': 0,
      'mobi_app': 'android',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statisticsApp,
      'version': '8.43.0',
      'id': id,
      'id_type': type,
      'room_id': roomId,
      'type': 'dislike',
      'page': page,
    };
    AppSign.appSign(params);
    return await Request().requestApi(
      Api.liveFeedback,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      options: Options(method: 'GET', extra: {'account': account}),
      queryParameters: params,
    );
  }
}

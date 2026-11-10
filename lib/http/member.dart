import 'dart:io';

import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/http/error_msg.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/member/archive_order_type_app.dart';
import 'package:pili_aurora/models/common/member/archive_order_type_web.dart';
import 'package:pili_aurora/models/common/member/archive_sort_type_app.dart';
import 'package:pili_aurora/models/common/member/contribute_type.dart';
import 'package:pili_aurora/models/common/member/web_ss_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/models/member/info.dart';
import 'package:pili_aurora/models/member/tags.dart';
import 'package:pili_aurora/models/remote/follow/data.dart';
import 'package:pili_aurora/models/remote/follow/list.dart';
import 'package:pili_aurora/models/remote/member/coin_like_arc/data.dart';
import 'package:pili_aurora/models/remote/member/search_archive/data.dart';
import 'package:pili_aurora/models/remote/member/season_web/data.dart';
import 'package:pili_aurora/models/remote/member_card_info/data.dart';
import 'package:pili_aurora/models/remote/member_guard/data.dart';
import 'package:pili_aurora/models/remote/space/space/data.dart';
import 'package:pili_aurora/models/remote/space/space_archive/data.dart';
import 'package:pili_aurora/models/remote/space/space_article/data.dart';
import 'package:pili_aurora/models/remote/space/space_audio/data.dart';
import 'package:pili_aurora/models/remote/space/space_cheese/data.dart';
import 'package:pili_aurora/models/remote/space/space_opus/data.dart';
import 'package:pili_aurora/models/remote/space/space_season_series/item.dart';
import 'package:pili_aurora/models/remote/space/space_shop/data.dart';
import 'package:pili_aurora/models/remote/upower_rank/data.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/app_sign.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:pili_aurora/utils/wbi_sign.dart';
import 'package:dio/dio.dart';

abstract final class MemberHttp {
  static Future<LoadingState<void>> reportMember(
    Object mid, {
    required Account account,
    required String reason,
    int? reasonV2,
  }) async {
    // 举报使用独立的 status 协议，不能套用 code/message/data 解码。
    Request();
    LoadingState<void> decode(Response<dynamic> response) {
      final body = response.data;
      if (body is! Map<String, dynamic> || body['status'] is! bool) {
        throw const FormatException('成员举报响应缺少布尔状态');
      }
      if (body['status'] == false) {
        final message = body['message'] ?? body['msg'];
        return Error(message is String ? message : '举报失败，请稍后重试');
      }
      final status = response.statusCode;
      if (status != null && (status < 200 || status >= 300)) {
        throw FormatException('举报成功状态与 HTTP $status 冲突');
      }
      return const Success(null);
    }

    try {
      final response = await Request.dio.post<dynamic>(
        Api.reportMember,
        data: {
          'mid': mid,
          'reason': reason,
          'reason_v2': ?reasonV2,
          'csrf': account.csrf,
        },
        options: Options(
          extra: {'account': account, 'noRetry': true},
          contentType: Headers.formUrlEncodedContentType,
        ),
      );
      return decode(response);
    } on DioException catch (error, stackTrace) {
      final response = error.response;
      if (response != null &&
          response.data is Map<String, dynamic> &&
          response.data['status'] == false) {
        final failure = decode(response) as Error;
        return Error(
          failure.errMsg,
          cause: error,
          stackTrace: stackTrace,
        );
      }
      return UnknownResult(cause: error, stackTrace: stackTrace);
    } catch (error, stackTrace) {
      Error.fromException(error, stackTrace);
      return UnknownResult(cause: error, stackTrace: stackTrace);
    }
  }

  static Future<LoadingState<SpaceArticleData>> spaceArticle({
    required Account account,
    required int mid,
    required int page,
  }) async {
    final params = {
      'build': 8430300,
      'channel': 'master',
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'mobi_app': 'android',
      'platform': 'android',
      'pn': page,
      'ps': 10,
      's_locale': 'zh_CN',
      'statistics': Constants.statisticsApp,
      'vmid': mid,
    };
    return await Request().requestApi(
      Api.spaceArticle,
      kind: ApiCallKind.query,
      decode: (body) => SpaceArticleData.fromJson(body['data']),
      queryParameters: params,
      options: Options(
        extra: {'account': account},
        headers: {
          'bili-http-engine': 'cronet',
          'user-agent': Constants.userAgentApp,
        },
      ),
    );
  }

  static Future<LoadingState<SpaceSsData>> seasonSeriesList({
    required Account account,
    required int? mid,
    required int pn,
  }) async {
    return await Request().requestApi(
      Api.seasonSeries,
      kind: ApiCallKind.query,
      decode: (body) =>
          SpaceSsData.fromJson(body['data']?['items_lists'] ?? {}),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'mid': mid,
        'page_num': pn,
        'page_size': 10,
      },
    );
  }

  static Future<LoadingState<SpaceArchiveData>> spaceArchive({
    Account? account,
    required ContributeType type,
    required int? mid,
    String? aid,
    ArchiveOrderTypeApp? order,
    ArchiveSortTypeApp? sort,
    int? pn,
    int? next,
    int? seasonId,
    int? seriesId,
    bool? includeCursor,
  }) async {
    account ??= Accounts.main;
    final params = {
      'aid': ?aid,
      'build': 8430300,
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'channel': 'master',
      'mobi_app': 'android',
      'platform': 'android',
      's_locale': 'zh_CN',
      'ps': 20,
      'pn': ?pn,
      'next': ?next,
      'season_id': ?seasonId,
      'series_id': ?seriesId,
      'qn': type == .video ? 80 : 32,
      'order': ?order?.name,
      'sort': ?sort?.name,
      'include_cursor': ?includeCursor,
      'statistics': Constants.statisticsApp,
      'vmid': mid,
    };
    return await Request().requestApi(
      type.api,
      kind: ApiCallKind.query,
      decode: (body) => SpaceArchiveData.fromJson(body['data']),
      queryParameters: params,
      options: Options(
        extra: {'account': account},
        headers: {
          'bili-http-engine': 'cronet',
          'user-agent': Constants.userAgentApp,
        },
      ),
    );
  }

  static Future<LoadingState<SpaceAudioData>> spaceAudio({
    required Account account,
    required int page,
    required mid,
  }) async {
    return await Request().requestApi(
      Api.spaceAudio,
      kind: ApiCallKind.query,
      decode: (body) => SpaceAudioData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'pn': page,
        'ps': 20,
        'order': 1,
        'uid': mid,
        'web_location': 333.1387,
      },
    );
  }

  static Future<LoadingState<SpaceCheeseData>> spaceCheese({
    required Account account,
    required int page,
    required mid,
  }) async {
    return await Request().requestApi(
      Api.spaceCheese,
      kind: ApiCallKind.query,
      decode: (body) => SpaceCheeseData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'pn': page,
        'ps': 30,
        'mid': mid,
        'web_location': 333.1387,
      },
    );
  }

  static Future<LoadingState<SpaceData>> space({
    Account? account,
    int? mid,
    dynamic fromViewAid,
  }) async {
    account ??= Accounts.main;
    final params = {
      'build': 8430300,
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'channel': 'master',
      'mobi_app': 'android',
      'platform': 'android',
      's_locale': 'zh_CN',
      'from_view_aid': ?fromViewAid,
      'statistics': Constants.statisticsApp,
      'vmid': mid,
    };
    return await Request().requestApi(
      Api.space,
      kind: ApiCallKind.query,
      decode: (body) => SpaceData.fromJson(body['data']),
      queryParameters: params,
      options: Options(
        extra: {'account': account},
        headers: {
          'bili-http-engine': 'cronet',
          'user-agent': Constants.userAgentApp,
        },
      ),
    );
  }

  static Future<LoadingState<MemberInfoModel>> memberInfo({
    Account? account,
    required int mid,
    String token = '',
  }) async {
    try {
      account ??= Accounts.main;
      String dmImgStr = Utils.base64EncodeRandomString(16, 64);
      String dmCoverImgStr = Utils.base64EncodeRandomString(32, 128);
      final params = await WbiSign.makSign({
        'mid': mid,
        'token': token,
        'platform': 'web',
        'web_location': 1550101,
        'dm_img_list': '[]',
        'dm_img_str': dmImgStr,
        'dm_cover_img_str': dmCoverImgStr,
        'dm_img_inter': '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
      });
      return await Request().requestApi(
        Api.memberInfo,
        kind: ApiCallKind.query,
        decode: (body) => MemberInfoModel.fromJson(body['data']),
        queryParameters: params,
        options: Options(
          extra: {'account': account},
          headers: {
            'origin': 'https://space.bilibili.com',
            'referer': 'https://space.bilibili.com/$mid/dynamic',
            'user-agent': BrowserUa.pc,
          },
        ),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<Map<String, dynamic>>> memberStat({
    Account? account,
    int? mid,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi(
      Api.userStat,
      kind: ApiCallKind.query,
      options: Options(extra: {'account': account}),
      decode: (body) => body['data'] as Map<String, dynamic>,
      queryParameters: {'vmid': mid},
    );
  }

  static Future<LoadingState<MemberCardInfoData>> memberCardInfo({
    int? mid,
    required Account account,
  }) async {
    return await Request().requestApi(
      Api.memberCardInfo,
      kind: ApiCallKind.query,
      decode: (body) => MemberCardInfoData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'mid': mid,
        'photo': false,
      },
    );
  }

  static Future<LoadingState<SearchArchiveData>> searchArchive({
    Account? account,
    required Object mid,
    int tid = 0, // e.g. pugv: 196
    int ps = 30,
    required int pn,
    String? keyword,
    String? specialType, // e.g. 'charging'
    ArchiveOrderTypeWeb order = .pubdate,
  }) async {
    try {
      account ??= Accounts.main;
      String dmImgStr = Utils.base64EncodeRandomString(16, 64);
      String dmCoverImgStr = Utils.base64EncodeRandomString(32, 128);
      final params = await WbiSign.makSign({
        'mid': mid,
        'ps': ps,
        'tid': tid,
        'pn': pn,
        'keyword': ?keyword,
        'special_type': ?specialType,
        'order': order.name,
        'platform': 'web',
        'web_location': 333.1387,
        'order_avoided': true,
        'dm_img_list': '[]',
        'dm_img_str': dmImgStr,
        'dm_cover_img_str': dmCoverImgStr,
        'dm_img_inter': '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
      });
      return await Request().requestApi(
        Api.searchArchive,
        kind: ApiCallKind.query,
        errorMessages: errorMsg,
        decode: (body) => SearchArchiveData.fromJson(body['data']),
        queryParameters: params,
        options: Options(
          extra: {'account': account},
          headers: {
            HttpHeaders.userAgentHeader: BrowserUa.pc,
            HttpHeaders.refererHeader: '${HttpString.spaceBaseUrl}/$mid',
            'origin': HttpString.spaceBaseUrl,
          },
        ),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<SeasonWebData>> seasonSeriesWeb({
    Account? account,
    required WebSsType type,
    required Object mid,
    required Object id,
    int ps = 30,
    required int pn,
    ArchiveSortTypeApp sort = .desc,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi(
      type.api,
      kind: ApiCallKind.query,
      errorMessages: errorMsg,
      decode: (body) => SeasonWebData.fromJson(body['data']),
      queryParameters: switch (type) {
        .season => {
          'mid': mid,
          'season_id': id,
          'sort_reverse': sort == .asc,
          'page_size': ps,
          'page_num': pn,
          'web_location': 333.1387,
        },
        .series => {
          'mid': mid,
          'series_id': id,
          'sort': sort.name,
          'ps': ps,
          'pn': pn,
          'web_location': 333.1387,
        },
      },
      options: Options(
        extra: {'account': account},
        headers: {
          HttpHeaders.userAgentHeader: BrowserUa.pc,
          HttpHeaders.refererHeader: '${HttpString.spaceBaseUrl}/$mid',
          'origin': HttpString.spaceBaseUrl,
        },
      ),
    );
  }

  // 用户动态
  @pragma('vm:notify-debugger-on-exception')
  static Future<LoadingState<DynamicsDataModel>> memberDynamic({
    Account? account,
    String? offset,
    required int mid,
  }) async {
    account ??= Accounts.main;
    final offsets = {offset};
    try {
      for (var page = 0; page < 100; page++) {
        final result = await Request().requestApi(
          Api.memberDynamic,
          kind: ApiCallKind.query,
          decode: (body) => DynamicsDataModel.fromJson(body['data']),
          errorMessages: errorMsg,
          queryParameters: await WbiSign.makSign({
            'offset': offset ?? '',
            'host_mid': mid,
            'timezone_offset': '-480',
            'features': Constants.dynFeatures,
            'platform': 'web',
            'web_location': '333.1387',
            'dm_img_list': '[]',
            'dm_img_str': Utils.base64EncodeRandomString(16, 64),
            'dm_cover_img_str': Utils.base64EncodeRandomString(32, 128),
            'dm_img_inter': '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
            'x-bili-device-req-json':
                '{"platform":"web","device":"pc","spmid":"333.1387"}',
          }),
          options: Options(
            extra: {'account': account},
            headers: {
              'user-agent': BrowserUa.pc,
              'origin': 'https://space.bilibili.com',
              'referer': 'https://space.bilibili.com/$mid/dynamic',
            },
          ),
        );
        if (result is Error) return result;
        final data = result.data;
        if (data.loadNext != true) return result;
        offset = data.offset;
        if (offset == null || offset.isEmpty || !offsets.add(offset)) {
          return const Error('动态分页未取得进展，请重试');
        }
      }
      return const Error('动态过滤页数过多，请调整过滤条件后重试');
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<DynamicsDataModel>> dynSearch({
    required Account account,
    required int pn,
    required dynamic mid,
    required dynamic offset,
    required String keyword,
  }) async {
    return await Request().requestApi(
      Api.dynSearch,
      kind: ApiCallKind.query,
      decode: (body) => DynamicsDataModel.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'host_mid': mid,
        'page': pn,
        'offset': offset,
        'keyword': keyword,
        'features': Constants.dynFeatures,
        'web_location': 333.1387,
      },
    );
  }

  // 查询分组
  static Future<LoadingState<List<MemberTagItemModel>>> followUpTags({
    required Account account,
  }) async {
    return await Request().requestApi(
      Api.followUpTag,
      kind: ApiCallKind.query,
      decode: (body) => (body['data'] as List)
          .map((e) => MemberTagItemModel.fromJson(e))
          .toList(),
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<void>> specialAction({
    required Account account,
    required int fid,
    bool isAdd = true,
  }) {
    return Request().requestApi<void>(
      isAdd ? Api.addSpecial : Api.delSpecial,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'fid': fid,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  // 设置分组
  static Future<LoadingState<void>> addUsers(
    String fids,
    String tagids, {
    required Account account,
  }) {
    return Request().requestApi<void>(
      Api.addUsers,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      queryParameters: {
        'x-bili-device-req-json':
            '{"platform":"web","device":"pc","spmid":"333.1387"}',
      },
      data: {
        'fids': fids,
        'tagids': tagids,
        'csrf': account.csrf,
        // 'cross_domain': true
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  // 获取某分组下的up
  static Future<LoadingState<FollowData>> followUpGroup({
    required Account account,
    required int mid,
    required int tagid,
    required int pn,
    int ps = 20,
    String orderType = '', // ''=>最近关注，'attention'=>最常访问
  }) async {
    return await Request().requestApi(
      Api.followUpGroup,
      kind: ApiCallKind.query,
      errorMessages: errorMsg,
      decode: (body) => FollowData(
        list:
            (body['data'] as List?)
                ?.map<FollowItemModel>((e) => FollowItemModel.fromJson(e))
                .toList() ??
            <FollowItemModel>[],
      ),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'mid': mid,
        'tagid': tagid,
        'pn': pn,
        'ps': ps,
        'order_type': orderType,
      },
    );
  }

  static Future<LoadingState<int>> createFollowTag(
    String tagName, {
    required Account account,
  }) {
    return Request().requestApi<int>(
      Api.createFollowTag,
      kind: ApiCallKind.mutation,
      decode: (body) {
        final data = body['data'];
        final id = data is Map<String, dynamic> ? data['tagid'] : null;
        if (id is! int || id <= 0) {
          throw const FormatException('新建分组响应缺少有效 ID');
        }
        return id;
      },
      queryParameters: {
        'x-bili-device-req-json':
            '{"platform":"web","device":"pc","spmid":"333.1387"}',
      },
      data: {
        'tag': tagName,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<void>> updateFollowTag(
    int tagid,
    String name, {
    required Account account,
  }) {
    return Request().requestApi<void>(
      Api.updateFollowTag,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      queryParameters: {
        'x-bili-device-req-json':
            '{"platform":"web","device":"pc","spmid":"333.1387"}',
      },
      data: {
        'tagid': tagid,
        'name': name,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<void>> delFollowTag(
    int tagid, {
    required Account account,
  }) {
    return Request().requestApi<void>(
      Api.delFollowTag,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      queryParameters: {
        'x-bili-device-req-json':
            '{"platform":"web","device":"pc","spmid":"333.1387"}',
      },
      data: {
        'tagid': tagid,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  // 获取up播放数、点赞数
  static Future<LoadingState<Map<String, dynamic>>> memberView({
    Account? account,
    required int mid,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi(
      Api.getMemberViewApi,
      kind: ApiCallKind.query,
      options: Options(extra: {'account': account}),
      decode: (body) => body['data'] as Map<String, dynamic>,
      queryParameters: {'mid': mid},
    );
  }

  // 搜索follow
  static Future<LoadingState<FollowData>> followSearch({
    required Account account,
    required int mid,
    required int ps,
    required int pn,
    required String name,
  }) async {
    try {
      final data = {
        'vmid': mid,
        'pn': pn,
        'ps': ps,
        'order': 'desc',
        'order_type': 'attention',
        'gaia_source': 'main_web',
        'name': name,
        'web_location': 333.999,
      };
      Map params = await WbiSign.makSign(data);
      return await Request().requestApi(
        Api.followSearch,
        kind: ApiCallKind.query,
        decode: (body) => FollowData.fromJson(body['data']),
        options: Options(extra: {'account': account}),
        queryParameters: {
          ...data,
          'w_rid': params['w_rid'],
          'wts': params['wts'],
        },
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<SpaceOpusData>> spaceOpus({
    Account? account,
    required int hostMid,
    required int page,
    String offset = '',
    String type = 'all',
  }) async {
    try {
      account ??= Accounts.main;
      return await Request().requestApi(
        Api.spaceOpus,
        kind: ApiCallKind.query,
        options: Options(extra: {'account': account}),
        decode: (body) => SpaceOpusData.fromJson(body['data']),
        queryParameters: await WbiSign.makSign({
          'host_mid': hostMid,
          'page': page,
          'offset': offset,
          'type': type,
          'web_location': 333.1387,
        }),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<UpowerRankData>> upowerRank({
    required Account account,
    required Object upMid,
    required int page,
    int? privilegeType,
  }) async {
    return await Request().requestApi(
      Api.upowerRank,
      kind: ApiCallKind.query,
      decode: (body) => UpowerRankData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'up_mid': upMid,
        'pn': page,
        'ps': 100,
        'privilege_type': ?privilegeType,
        'mobi_app': 'web',
        'web_location': 333.1196,
        if (account.isLogin) 'csrf': account.csrf,
      },
    );
  }

  static Future<LoadingState<CoinLikeArcData>> coinArc({
    required Account account,
    required int mid,
    required int page,
  }) async {
    return await Request().requestApi(
      Api.coinArc,
      kind: ApiCallKind.query,
      decode: (body) => CoinLikeArcData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'pn': page,
        'ps': 20,
        'vmid': mid,
      },
    );
  }

  static Future<LoadingState<CoinLikeArcData>> likeArc({
    required Account account,
    required int mid,
    required int page,
  }) async {
    return await Request().requestApi(
      Api.likeArc,
      kind: ApiCallKind.query,
      decode: (body) => CoinLikeArcData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'pn': page,
        'ps': 20,
        'vmid': mid,
      },
    );
  }

  static Future<LoadingState<SpaceShopData>> spaceShop({
    required Account account,
    required int mid,
  }) async {
    final params = {
      'access_key': ?account.accessKey,
      'actionKey': 'appkey',
      'build': 8430300,
      'mVersion': 309,
      'mallVersion': 8430300,
      'statistics': Constants.statisticsApp,
    };
    AppSign.appSign(params);
    return await Request().requestApi(
      Api.spaceShop,
      kind: ApiCallKind.query,
      decode: (body) => SpaceShopData.fromJson(body['data']),
      options: Options(method: 'POST', extra: {'account': account}),
      queryParameters: params,
      data: {
        "from": "cps_productTab_$mid",
        "searchAfter": 0,
        "msource": "cps_productTab_$mid",
        "pageSize": 8,
        "upMid": mid.toString(),
      },
    );
  }

  static Future<LoadingState<MemberGuardData>> memberGuard({
    required Account account,
    required Object ruid,
    required int page,
  }) async {
    return await Request().requestApi(
      Api.memberGuard,
      kind: ApiCallKind.query,
      decode: (body) => MemberGuardData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'page': page,
        'page_size': 20,
        'ruid': ruid,
      },
    );
  }
}

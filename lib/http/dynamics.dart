import 'dart:convert';

import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/common/widgets/pair.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/http/error_msg.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/reply.dart';
import 'package:pili_aurora/models/common/dynamic/dynamics_type.dart';
import 'package:pili_aurora/models/common/reply/reply_option_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/models/dynamics/up.dart';
import 'package:pili_aurora/models/dynamics/vote_model.dart';
import 'package:pili_aurora/models/remote/article/article_info/data.dart';
import 'package:pili_aurora/models/remote/article/article_list/data.dart';
import 'package:pili_aurora/models/remote/article/article_view/data.dart';
import 'package:pili_aurora/models/remote/bubble/data.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_mention/data.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_mention/group.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_reaction/data.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_reserve/data.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_reserve_info/data.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_feed/topic_card_list.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_top/top_details.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_top/topic_item.dart';
import 'package:pili_aurora/models/remote/followee_votes/vote.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/accounts/account_manager/account_mgr.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:pili_aurora/utils/wbi_sign.dart';
import 'package:dio/dio.dart';

abstract final class DynamicsHttp {
  @pragma('vm:notify-debugger-on-exception')
  static Future<LoadingState<DynamicsDataModel>> followDynamic({
    Account? account,
    int? hostMid,
    String? offset,
    Set<int>? tempBannedList,
    DynamicsTabType type = .all,
  }) async {
    account ??= AccountManager.resolveAccount(Api.followDynamic);
    final banned = tempBannedList == null ? null : Set<int>.of(tempBannedList);
    final offsets = {offset};
    for (var page = 0; page < 100; page++) {
      final result = await Request().requestApi(
        Api.followDynamic,
        kind: ApiCallKind.query,
        decode: (body) => DynamicsDataModel.fromJson(
          body['data'],
          type: type,
          tempBannedList: banned,
        ),
        errorMessages: const {4101132: '没有数据'},
        queryParameters: {
          if (type == .up) 'host_mid': hostMid else 'type': type.name,
          'offset': ?offset,
          'features': Constants.dynFeatures,
        },
        options: Options(extra: {'account': account}),
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
  }

  static Future<LoadingState<FollowUpModel>> followUp({
    Account? account,
  }) async {
    account ??= AccountManager.resolveAccount(Api.followUp);
    return await Request().requestApi(
      Api.followUp,
      kind: ApiCallKind.query,
      decode: (body) => FollowUpModel.fromJson(body['data']),
      queryParameters: {
        'up_list_more': 1,
        'web_location': 333.1365,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<FollowUpModel>> dynUpList(
    String? offset, {
    Account? account,
  }) async {
    account ??= AccountManager.resolveAccount(Api.dynUplist);
    return await Request().requestApi(
      Api.dynUplist,
      kind: ApiCallKind.query,
      decode: (body) => FollowUpModel.fromUpList(body['data']),
      queryParameters: {
        'offset': ?offset,
        'platform': 'web',
        'web_location': 333.1365,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<FollowUpModel>> followings({
    Account? account,
    int? vmid,
    int? pn,
    int ps = 20,
    String orderType = '', // ''=>最近关注，'attention'=>最常访问
  }) async {
    account ??= AccountManager.resolveAccount(Api.followings);
    return await Request().requestApi(
      Api.followings,
      errorMessages: errorMsg,
      kind: ApiCallKind.query,
      decode: (body) => FollowUpModel.fromFollowList(body['data']),
      queryParameters: {
        'vmid': vmid,
        'pn': pn,
        'ps': ps,
        'order': 'desc',
        'order_type': orderType,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<void>> thumbDynamic({
    Account? account,
    required String? dynamicId,
    required int? up,
  }) async {
    account ??= AccountManager.resolveAccount(Api.thumbDynamic);
    return await Request().requestApi(
      Api.thumbDynamic,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      queryParameters: {
        'csrf': account.csrf,
      },
      data: {
        'dyn_id_str': dynamicId,
        'up': up,
        'spmid': '333.1365.0.0',
      },
      options: Options(
        extra: {'account': account},
        headers: {
          'referer': HttpString.dynamicShareBaseUrl,
        },
      ),
    );
  }

  static Future<LoadingState<String?>> createDynamic({
    Account? account,
    dynamic mid,
    dynamic dynIdStr, // repost dyn
    dynamic rid, // repost video
    dynamic dynType,
    dynamic rawText,
    List? pics,
    int? publishTime,
    ReplyOptionType? replyOption,
    int? privatePub,
    List<Map<String, dynamic>>? extraContent,
    Pair<int, String>? topic,
    String? title,
    Map? attachCard,
  }) async {
    account ??= AccountManager.resolveAccount(Api.createDynamic);
    return await Request().requestApi(
      Api.createDynamic,
      kind: ApiCallKind.mutation,
      decode: (body) {
        final data = body['data'] as Map<String, dynamic>?;
        final id = data?['dyn_id'];
        if (id == null) return null;
        if ((id is! String && id is! int) ||
            (int.tryParse(id.toString()) ?? 0) <= 0) {
          throw const FormatException('动态 ID 无效');
        }
        return id.toString();
      },
      queryParameters: {
        'platform': 'web',
        'csrf': account.csrf,
        'x-bili-device-req-json': '{"platform": "web", "device": "pc"}',
        'x-bili-web-req-json': '{"spm_id": "333.999"}',
      },
      data: {
        "dyn_req": {
          "content": {
            "contents": [
              if (rawText != null)
                {
                  "raw_text": rawText,
                  "type": 1,
                  "biz_id": "",
                },
              ...?extraContent,
            ],
            if (title != null && title.isNotEmpty) 'title': title,
          },
          if (privatePub != null || replyOption != null || publishTime != null)
            "option": {
              'private_pub': ?privatePub,
              "timer_pub_time": ?publishTime,
              if (replyOption == ReplyOptionType.close)
                "close_comment": 1
              else if (replyOption == ReplyOptionType.choose)
                "up_choose_comment": 1,
            },
          "scene": rid != null
              ? 5
              : dynIdStr != null
              ? 4
              : pics != null
              ? 2
              : 1,
          'pics': ?pics,
          "attach_card": attachCard,
          "upload_id":
              "${rid != null ? 0 : mid}_${DateTime.now().millisecondsSinceEpoch ~/ 1000}_${Utils.random.nextInt(9000) + 1000}",
          "meta": {
            "app_meta": {"from": "create.dynamic.web", "mobi_app": "web"},
          },
          if (topic != null)
            "topic": {
              "id": topic.first,
              "name": topic.second,
              "from_source": "dyn.web.list",
              "from_topic_id": 0,
            },
        },
        if (dynIdStr != null || rid != null)
          "web_repost_src": {
            "dyn_id_str": ?dynIdStr,
            if (rid != null)
              "revs_id": {
                "dyn_type": dynType,
                "rid": rid,
              },
          },
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<DynamicItemModel>> dynamicDetail({
    Account? account,
    dynamic id,
    dynamic rid,
    dynamic type,
    bool clearCookie = false,
  }) async {
    account = clearCookie
        ? const NoAccount()
        : account ?? AccountManager.resolveAccount(Api.dynamicDetail);
    return await Request().requestApi(
      Api.dynamicDetail,
      kind: ApiCallKind.query,
      decode: (body) {
        final item = DynamicItemModel.fromJson(body['data']['item']);
        if ((int.tryParse(item.idStr.toString()) ?? 0) <= 0) {
          throw const FormatException('动态详情缺少有效 ID');
        }
        return item;
      },
      queryParameters: {
        'timezone_offset': -480,
        'id': ?id,
        'rid': ?rid,
        'type': ?type,
        'features': Constants.dynFeatures,
        'gaia_source': 'Athena',
        'web_location': '333.1330',
        'x-bili-device-req-json':
            '{"platform":"web","device":"pc","spmid":"333.1330"}',
        if (!clearCookie && account.isLogin) 'csrf': account.csrf,
      },
      options: clearCookie
          ? ReplyHttp.options
          : Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<void>> setTop({
    Account? account,
    required Object dynamicId,
  }) async {
    account ??= AccountManager.resolveAccount(Api.setTopDyn);
    return await Request().requestApi(
      Api.setTopDyn,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      queryParameters: {
        'csrf': account.csrf,
      },
      data: {
        'dyn_str': dynamicId,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<void>> rmTop({
    Account? account,
    required Object dynamicId,
  }) async {
    account ??= AccountManager.resolveAccount(Api.rmTopDyn);
    return await Request().requestApi(
      Api.rmTopDyn,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      queryParameters: {
        'csrf': account.csrf,
      },
      data: {
        'dyn_str': dynamicId,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<ArticleInfoData>> articleInfo({
    Account? account,
    required Object cvId,
  }) async {
    account ??= AccountManager.resolveAccount(Api.articleInfo);
    try {
      return await Request().requestApi(
        Api.articleInfo,
        kind: ApiCallKind.query,
        decode: (body) => ArticleInfoData.fromJson(body['data']),
        queryParameters: await WbiSign.makSign({
          'id': cvId,
          'mobi_app': 'pc',
          'from': 'web',
          'gaia_source': 'main_web',
        }),
        options: Options(extra: {'account': account}),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<ArticleViewData>> articleView({
    Account? account,
    required dynamic cvId,
  }) async {
    account ??= AccountManager.resolveAccount(Api.articleView);
    try {
      return await Request().requestApi(
        Api.articleView,
        kind: ApiCallKind.query,
        decode: (body) => ArticleViewData.fromJson(body['data']),
        queryParameters: await WbiSign.makSign({
          'id': cvId,
          'gaia_source': 'main_web',
          'web_location': '333.976',
        }),
        options: Options(extra: {'account': account}),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<DynamicItemModel>> opusDetail({
    Account? account,
    required dynamic opusId,
  }) async {
    account ??= AccountManager.resolveAccount(Api.opusDetail);
    try {
      return await Request().requestApi(
        Api.opusDetail,
        kind: ApiCallKind.query,
        decode: (body) {
          final item = DynamicItemModel.fromOpusJson(body['data']);
          if (item.fallback?.id == null &&
              (item.basic?.commentType == null ||
                  (int.tryParse(item.basic?.commentIdStr ?? '') ?? 0) <= 0)) {
            throw const FormatException('图文详情缺少评论来源');
          }
          return item;
        },
        queryParameters: await WbiSign.makSign({
          'timezone_offset': '-480',
          'features': 'htmlNewStyle',
          'id': opusId,
        }),
        options: Options(extra: {'account': account}),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<VoteInfo>> voteInfo(
    dynamic voteId, {
    Account? account,
  }) async {
    account ??= AccountManager.resolveAccount(Api.voteInfo);
    return await Request().requestApi(
      Api.voteInfo,
      kind: ApiCallKind.query,
      decode: (body) =>
          _validateVote(VoteInfo.fromSeparatedJson(body['data']), voteId),
      queryParameters: {'vote_id': voteId},
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<VoteInfo>> doVote({
    Account? account,
    required int voteId,
    required List<int> votes,
    bool anonymous = false,
    int? dynamicId,
  }) async {
    account ??= AccountManager.resolveAccount(Api.doVote);
    final csrf = account.csrf;
    final data = {
      'vote_id': voteId,
      'votes': votes,
      'voter_uid': account.mid,
      'status': anonymous ? 1 : 0,
      'op_bit': 0,
      'dynamic_id': dynamicId ?? 0,
      'csrf_token': csrf,
      'csrf': csrf,
    };
    return await Request().requestApi(
      Api.doVote,
      kind: ApiCallKind.mutation,
      decode: (body) =>
          _validateVote(VoteInfo.fromJson(body['data']['vote_info']), voteId),
      queryParameters: {'csrf': csrf},
      data: data,
      options: Options(
        extra: {'account': account},
        contentType: Headers.jsonContentType,
      ),
    );
  }

  static Future<LoadingState<TopDetails?>> topicTop({
    Account? account,
    required Object topicId,
  }) async {
    account ??= AccountManager.resolveAccount(Api.topicTop);
    return await Request().requestApi(
      Api.topicTop,
      kind: ApiCallKind.query,
      decode: (body) {
        final data = body['data']?['top_details'];
        return data == null ? null : TopDetails.fromJson(data);
      },
      queryParameters: {
        'topic_id': topicId,
        'source': 'Web',
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<TopicCardList?>> topicFeed({
    Account? account,
    required Object topicId,
    String? offset,
    required int sortBy,
  }) async {
    account ??= AccountManager.resolveAccount(Api.topicFeed);
    return await Request().requestApi(
      Api.topicFeed,
      kind: ApiCallKind.query,
      decode: (body) {
        final data = body['data']?['topic_card_list'];
        return data == null ? null : TopicCardList.fromJson(data);
      },
      queryParameters: {
        'topic_id': topicId,
        'sort_by': sortBy,
        'offset': ?offset,
        'page_size': 20,
        'source': 'Web',
        'features': Constants.dynFeatures,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<TopicCardList?>> topicFold({
    Account? account,
    required Object topicId,
    required int sortBy,
  }) async {
    account ??= AccountManager.resolveAccount(Api.topicFold);
    return await Request().requestApi(
      Api.topicFold,
      kind: ApiCallKind.query,
      decode: (body) {
        final data = body['data']?['topic_card_list'];
        return data == null ? null : TopicCardList.fromJson(data);
      },
      queryParameters: {
        'topic_id': topicId,
        'sort_by': sortBy,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<ArticleListData>> articleList({
    required Object id,
    required Account account,
  }) async {
    return await Request().requestApi(
      Api.articleList,
      kind: ApiCallKind.query,
      decode: (body) => ArticleListData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'id': id,
        'web_location': 333.1400,
      },
    );
  }

  static Future<LoadingState<DynReserveData>> dynReserve({
    Account? account,
    required Object? reserveId,
    required Object? curBtnStatus,
    required Object dynamicIdStr,
    required Object? reserveTotal,
  }) async {
    account ??= AccountManager.resolveAccount(Api.dynReserve);
    return await Request().requestApi(
      Api.dynReserve,
      kind: ApiCallKind.mutation,
      decode: (body) {
        final data = DynReserveData.fromJson(body['data']);
        if (data.finalBtnStatus == null) {
          throw const FormatException('预约结果缺少最终状态');
        }
        return data;
      },
      queryParameters: {
        'csrf': account.csrf,
      },
      data: {
        'reserve_id': ?reserveId,
        'cur_btn_status': ?curBtnStatus,
        'dynamic_id_str': dynamicIdStr,
        'reserve_total': ?reserveTotal,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<List<TopicItem>?>> dynTopicRcmd({
    Account? account,
    int ps = 25,
  }) async {
    account ??= AccountManager.resolveAccount(Api.dynTopicRcmd);
    return await Request().requestApi(
      Api.dynTopicRcmd,
      kind: ApiCallKind.query,
      decode: (body) => (body['data']?['topic_items'] as List?)
          ?.map((e) => TopicItem.fromJson(e))
          .toList(),
      queryParameters: {
        'source': 'Web',
        'page_size': ps,
        'web_location': 333.1365,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<List<OpusPicModel>?>> dynPic(
    dynamic id, {
    Account? account,
  }) async {
    account ??= AccountManager.resolveAccount(Api.dynPic);
    return await Request().requestApi(
      Api.dynPic,
      kind: ApiCallKind.query,
      decode: (body) => (body['data'] as List?)
          ?.map((e) => OpusPicModel.fromJson(e))
          .toList(),
      queryParameters: {
        'id': id,
        'web_location': 333.1368,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<List<MentionGroup>?>> dynMention({
    Account? account,
    String? keyword,
  }) async {
    account ??= AccountManager.resolveAccount(Api.dynMention);
    return await Request().requestApi(
      Api.dynMention,
      kind: ApiCallKind.query,
      decode: (body) => DynMentionData.fromJson(body['data']).groups,
      queryParameters: {
        if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
        'web_location': 333.1365,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<int>> createVote(
    VoteInfo voteInfo, {
    Account? account,
  }) async {
    account ??= AccountManager.resolveAccount(Api.createVote);
    return await Request().requestApi(
      Api.createVote,
      kind: ApiCallKind.mutation,
      decode: (body) {
        final id = body['data']?['vote_id'];
        if (id is! int || id <= 0) throw const FormatException('缺少有效的投票 ID');
        return id;
      },
      queryParameters: {'csrf': account.csrf},
      data: {'vote_info': voteInfo.toJson()},
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<int>> updateVote(
    VoteInfo voteInfo, {
    Account? account,
  }) async {
    account ??= AccountManager.resolveAccount(Api.updateVote);
    return await Request().requestApi(
      Api.updateVote,
      kind: ApiCallKind.mutation,
      decode: (body) {
        final id = body['data']?['vote_id'] ?? voteInfo.voteId;
        if (id is! int || id <= 0) throw const FormatException('缺少有效的投票 ID');
        if (id != voteInfo.voteId) throw const FormatException('投票结果与目标不符');
        return id;
      },
      queryParameters: {'csrf': account.csrf},
      data: {'vote_info': voteInfo.toJson()},
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<int>> createReserve({
    Account? account,
    int subType = 0,
    required String title,
    required int livePlanStartTime,
  }) async {
    account ??= AccountManager.resolveAccount(Api.createReserve);
    return await Request().requestApi(
      Api.createReserve,
      kind: ApiCallKind.mutation,
      decode: (body) {
        final id = body['data']?['sid'];
        if (id is! int || id <= 0) throw const FormatException('缺少有效的预约 ID');
        return id;
      },
      data: {
        'type': 2,
        'sub_type': subType,
        'from': 1,
        'title': title,
        'live_plan_start_time': livePlanStartTime,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<int>> updateReserve({
    Account? account,
    int subType = 0,
    required String title,
    required int livePlanStartTime,
    required int sid,
  }) async {
    account ??= AccountManager.resolveAccount(Api.updateReserve);
    return await Request().requestApi(
      Api.updateReserve,
      kind: ApiCallKind.mutation,
      decode: (body) {
        final id = body['data']?['sid'] ?? sid;
        if (id is! int || id <= 0) throw const FormatException('缺少有效的预约 ID');
        if (id != sid) throw const FormatException('预约结果与目标不符');
        return id;
      },
      data: {
        'type': 2,
        'sub_type': subType,
        'from': 1,
        'title': title,
        'live_plan_start_time': livePlanStartTime,
        'id': sid,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<ReserveInfoData>> reserveInfo({
    Account? account,
    required dynamic sid,
  }) async {
    account ??= AccountManager.resolveAccount(Api.reserveInfo);
    return await Request().requestApi(
      Api.reserveInfo,
      kind: ApiCallKind.query,
      decode: (body) {
        final info = ReserveInfoData.fromJson(body['data']);
        if (info.id.toString() != sid.toString() ||
            info.title == null ||
            info.livePlanStartTime == null) {
          throw const FormatException('预约信息不完整');
        }
        return info;
      },
      queryParameters: {
        'from': 1,
        'id': sid,
        'web_location': 333.1365,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<List<FolloweeVote>?>> followeeVotes({
    Account? account,
    required dynamic voteId,
  }) async {
    account ??= AccountManager.resolveAccount(Api.followeeVotes);
    return await Request().requestApi(
      Api.followeeVotes,
      kind: ApiCallKind.query,
      decode: (body) => (body['data']?['votes'] as List?)
          ?.map((e) => FolloweeVote.fromJson(e))
          .toList(),
      queryParameters: {
        'vote_id': voteId,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<void>> dynPrivatePubSetting({
    Account? account,
    required Object dynId,
    int? dynType,
    required String action,
  }) async {
    account ??= AccountManager.resolveAccount(Api.dynPrivatePubSetting);
    return await Request().requestApi(
      Api.dynPrivatePubSetting,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      queryParameters: {
        'platform': 'web',
        'csrf': account.csrf,
      },
      data: {
        "object_id": jsonEncode({
          "dyn_id": dynId.toString(),
          "dyn_type": ?dynType,
        }),
        "action": action,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.jsonContentType,
      ),
    );
  }

  static Future<LoadingState<void>> editDyn({
    Account? account,
    required Object dynId,
    Object? repostDynId,
    dynamic rawText,
    List? pics,
    ReplyOptionType? replyOption,
    int? privatePub,
    List<Map<String, dynamic>>? extraContent,
    Pair<int, String>? topic,
    String? title,
    Map? attachCard,
  }) async {
    account ??= AccountManager.resolveAccount(Api.editDyn);
    final uploadId =
        "${account.mid}_${DateTime.now().millisecondsSinceEpoch ~/ 1000}_${Utils.random.nextInt(9000) + 1000}";
    try {
      return await Request().requestApi(
        Api.editDyn,
        kind: ApiCallKind.mutation,
        decode: (_) {},
        queryParameters: await WbiSign.makSign({
          'platform': 'web',
          'csrf': account.csrf,
          'x-bili-device-req-json':
              '{"platform":"web","device":"pc","spmid":"333.1368"}',
          'w_dyn_req.upload_id': uploadId,
          'w_dyn_req.meta':
              '{"app_meta":{"from":"create.dynamic.web","mobi_app":"web"}}',
        }),
        data: {
          "dyn_req": {
            "content": {
              "contents": [
                if (rawText != null)
                  {
                    "raw_text": rawText,
                    "type": 1,
                    "biz_id": "",
                  },
                ...?extraContent,
              ],
              if (title != null && title.isNotEmpty) 'title': title,
            },
            if (privatePub != null || replyOption != null)
              "option": {
                'private_pub': ?privatePub,
                if (replyOption == ReplyOptionType.close)
                  "close_comment": 1
                else if (replyOption == ReplyOptionType.choose)
                  "up_choose_comment": 1,
              },
            "scene": repostDynId != null
                ? 4
                : pics != null
                ? 2
                : 1,
            'pics': ?pics,
            "attach_card": attachCard,
            "upload_id": uploadId,
            "meta": {
              "app_meta": {"from": "create.dynamic.web", "mobi_app": "web"},
            },
            if (topic != null)
              "topic": {
                "id": topic.first,
                "name": topic.second,
                "from_source": "dyn.web.list",
                "from_topic_id": 0,
              },
          },
          "dyn_id_str": dynId.toString(),
          if (repostDynId != null)
            "web_repost_src": {"dyn_id_str": repostDynId.toString()},
        },
        options: Options(
          extra: {'account': account},
          contentType: Headers.jsonContentType,
        ),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<BubbleData>> bubble({
    Account? account,
    required Object tribeId,
    Object? categoryId,
    int? sortType,
    required int page,
  }) async {
    account ??= AccountManager.resolveAccount(Api.bubble);
    return await Request().requestApi(
      Api.bubble,
      kind: ApiCallKind.query,
      decode: (body) => BubbleData.fromJson(body['data']),
      queryParameters: {
        'tribee_id': tribeId,
        'category_id': ?categoryId,
        'sort_type': ?sortType,
        'page_size': 20,
        'page_num': page,
        'web_location': 333.40165,
        'x-bili-device-req-json':
            '{"platform":"web","device":"pc","spmid":"333.40165"}',
      },
      options: Options(extra: {'account': account}),
    );
  }

  static Future<LoadingState<DynReactionData>> dynReaction({
    Account? account,
    required Object id,
    String? offset,
  }) async {
    account ??= AccountManager.resolveAccount(Api.dynReaction);
    return await Request().requestApi(
      Api.dynReaction,
      kind: ApiCallKind.query,
      decode: (body) => DynReactionData.fromJson(body['data']),
      queryParameters: {
        'id': id,
        'offset': ?offset,
        'web_location': 333.1369,
      },
      options: Options(extra: {'account': account}),
    );
  }

  static VoteInfo _validateVote(VoteInfo info, Object? voteId) {
    if (info.voteId == null ||
        info.voteId! <= 0 ||
        info.voteId.toString() != voteId.toString() ||
        info.title == null ||
        info.endTime == null ||
        info.choiceCnt == null ||
        info.options.isEmpty ||
        info.choiceCnt! < 1 ||
        info.choiceCnt! > info.options.length ||
        info.options.any((option) => option.optIdx == null)) {
      throw const FormatException('投票信息不完整');
    }
    return info;
  }
}

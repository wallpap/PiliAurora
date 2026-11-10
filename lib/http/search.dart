import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/search/search_type.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/search/result.dart';
import 'package:pili_aurora/models/search/suggest.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_pub_search/data.dart';
import 'package:pili_aurora/models/remote/pagelist/page_item.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/result.dart';
import 'package:pili_aurora/models/remote/search/search_rcmd/data.dart';
import 'package:pili_aurora/models/remote/search/search_trending/data.dart';
import 'package:pili_aurora/utils/extension/iterable_ext.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/wbi_sign.dart';
import 'package:dio/dio.dart';

class SearchVerificationRequired extends Error {
  const SearchVerificationRequired(this.voucher) : super('触发风控，请完成验证');
  final String voucher;
}

abstract final class SearchHttp {
  // 获取搜索建议
  @pragma('vm:notify-debugger-on-exception')
  static Future<LoadingState<SearchSuggestModel>> searchSuggest({
    required String term,
    Account? account,
  }) async {
    account ??= Accounts.get(AccountType.recommend);
    try {
      return await Request().requestApi(
        Api.searchSuggest,
        kind: ApiCallKind.query,
        decode: (body) => SearchSuggestModel.fromJson(body['data']['result']),
        queryParameters: await WbiSign.makSign({
          'term': term,
          'highlight': 0,
          'spmid': 333.1365,
          'web_location': 333.1365,
        }),
        options: Options(extra: {'account': account}),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  // 分类搜索
  @pragma('vm:notify-debugger-on-exception')
  static Future<LoadingState<R>> searchByType<R extends SearchNumData>({
    required SearchType searchType,
    required Account account,
    required String keyword,
    required page,
    String? order,
    int? duration,
    int? tids,
    int? orderSort,
    int? userType,
    int? categoryId,
    int? pubBegin,
    int? pubEnd,
    String? gaiaVtoken,
  }) async {
    try {
      final params = await WbiSign.makSign({
        'search_type': searchType.name,
        'keyword': keyword,
        'page': page,
        if (order != null && order.isNotEmpty) 'order': order,
        'duration': ?duration,
        'tids': ?tids,
        'order_sort': ?orderSort,
        'user_type': ?userType,
        'category_id': ?categoryId,
        'pubtime_begin_s': ?pubBegin,
        'pubtime_end_s': ?pubEnd,
        'page_size': 20,
        'platform': 'pc',
        'web_location': 1430654,
        'gaia_vtoken': ?gaiaVtoken,
      });
      final result = await Request().requestApi<Map<String, dynamic>>(
        searchType.api,
        kind: ApiCallKind.query,
        decode: (body) => body['data'] as Map<String, dynamic>,
        queryParameters: params,
        options: Options(
          extra: {'account': account},
          headers: {
            if (gaiaVtoken != null) 'cookie': 'x-bili-gaia-vtoken=$gaiaVtoken',
            'origin': 'https://search.bilibili.com',
            'referer':
                'https://search.bilibili.com/${searchType.name}?keyword=${Uri.encodeFull(keyword)}',
          },
        ),
      );
      if (result is Error) return result;
      final data = result.data;
      if (data['v_voucher'] case final voucher?) {
        if (voucher is! String || voucher.trim().isEmpty) {
          throw const FormatException('搜索验证凭据无效');
        }
        return SearchVerificationRequired(voucher);
      }
      return Success(
        switch (searchType) {
          .all => SearchVideoData.fromSearchAll(data),
          .video => SearchVideoData.fromJson(data),
          .media_bangumi || .media_ft => SearchPgcData.fromJson(data),
          .live_room => SearchLiveData.fromJson(data),
          .bili_user => SearchUserData.fromJson(data),
          .article => SearchArticleData.fromJson(data),
        } as R,
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<int?> ab2c({dynamic aid, dynamic bvid, int? part}) async {
    return (await ab2cWithDimension(aid: aid, bvid: bvid, part: part))?.cid;
  }

  static Future<PageItem?> ab2cWithDimension({
    dynamic aid,
    dynamic bvid,
    int? part,
  }) async {
    final result = await pageWithDimension(aid: aid, bvid: bvid, part: part);
    if (result is Error) result.toast();
    return result.dataOrNull;
  }

  /// 由页面消费结果，查询失败或无分 P 时不在 HTTP 层触发迟到提示。
  static Future<LoadingState<PageItem?>> pageWithDimension({
    Account? account,
    Object? aid,
    Object? bvid,
    int? part,
  }) {
    return Request().requestApi<PageItem?>(
      Api.ab2c,
      kind: ApiCallKind.query,
      options: Options(extra: {'account': account ?? Accounts.heartbeat}),
      decode: (body) {
        final list = body['data'] as List;
        final target = part != null
            ? (list.getOrNull(part - 1) ?? list.firstOrNull)
            : list.firstOrNull;
        if (target == null) return null;
        final page = PageItem.fromJson(target);
        if (page.cid <= 0) throw const FormatException('视频分 P 缺少有效 cid');
        return page;
      },
      queryParameters: {'aid': ?aid, 'bvid': ?bvid},
    );
  }

  static Future<LoadingState<PgcInfoModel>> pgcInfo({
    dynamic seasonId,
    dynamic epId,
  }) {
    return Request().requestApi(
      Api.pgcInfo,
      kind: ApiCallKind.query,
      decode: (body) => PgcInfoModel.fromJson(body['result']),
      queryParameters: {
        'season_id': ?seasonId,
        'ep_id': ?epId,
      },
    );
  }

  static Future<LoadingState<PgcInfoModel>> pugvInfo({
    Account? account,
    dynamic seasonId,
    dynamic epId,
  }) {
    return Request().requestApi(
      Api.pugvInfo,
      kind: ApiCallKind.query,
      options: Options(extra: {'account': account ?? Accounts.main}),
      decode: (body) => PgcInfoModel.fromJson(body['data']),
      queryParameters: {
        'season_id': ?seasonId,
        'ep_id': ?epId,
      },
    );
  }

  static Future<LoadingState<SearchTrendingData>> searchTrending({
    int limit = 30,
    bool needsTop = false,
  }) {
    return Request().requestApi(
      Api.searchTrending,
      kind: ApiCallKind.query,
      decode: (body) =>
          SearchTrendingData.fromJson(body['data'], needsTop: needsTop),
      queryParameters: {
        'limit': limit,
      },
    );
  }

  static Future<LoadingState<SearchRcmdData>> searchRecommend() {
    return Request().requestApi(
      Api.searchRecommend,
      kind: ApiCallKind.query,
      decode: (body) => SearchRcmdData.fromJson(body['data']),
      queryParameters: {
        'build': 8430300,
        'channel': 'master',
        'version': '8.43.0',
        'c_locale': 'zh_CN',
        'mobi_app': 'android',
        'platform': 'android',
        's_locale': 'zh_CN',
        'from': 2,
      },
    );
  }

  static Future<LoadingState<TopicPubSearchData>> topicPubSearch({
    required String keywords,
    String content = '',
    required int pageNum,
  }) {
    return Request().requestApi(
      Api.topicPubSearch,
      kind: ApiCallKind.query,
      decode: (body) => TopicPubSearchData.fromJson(body['data']),
      queryParameters: {
        'keywords': keywords,
        'content': content,
        if (pageNum == 1) ...{
          'page_size': 20,
          'page_num': 1,
        } else
          'offset': 20 * (pageNum - 1),
        'web_location': 333.1365,
      },
    );
  }
}

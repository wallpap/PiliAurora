import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/music/bgm_detail.dart';
import 'package:pili_aurora/models/remote/music/bgm_recommend_list.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/wbi_sign.dart';
import 'package:dio/dio.dart';

abstract final class MusicHttp {
  static Future<LoadingState<MusicDetail>> bgmDetail(
    String musicId, {
    Account? account,
  }) async {
    if (musicId.trim().isEmpty) return const Error('音乐标识无效，请重新打开页面');
    account ??= Accounts.main;
    try {
      return await Request().requestApi(
        Api.bgmDetail,
        kind: ApiCallKind.query,
        decode: (body) => MusicDetail.fromJson(body['data']),
        options: Options(extra: {'account': account}),
        queryParameters: await WbiSign.makSign({
          'music_id': musicId,
          'relation_from': 'bgm_page',
        }),
      );
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<void>> wishUpdate(
    String musicId,
    bool hasLike, {
    Account? account,
  }) async {
    if (musicId.trim().isEmpty) return const Error('音乐标识无效，请重新打开页面');
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.wishUpdate,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'music_id': musicId,
        'state': hasLike ? 2 : 1,
        'csrf': account.csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
  }

  static Future<LoadingState<List<BgmRecommend>?>> bgmRecommend(
    String musicId,
  ) async {
    if (musicId.trim().isEmpty) return const Error('音乐标识无效，请重新打开页面');
    return await Request().requestApi(
      Api.bgmRecommend,
      kind: ApiCallKind.query,
      decode: (body) => (body['data']?['list'] as List?)
          ?.map((item) => BgmRecommend.fromJson(item))
          .toList(),
      queryParameters: {
        'music_id': musicId,
      },
    );
  }
}

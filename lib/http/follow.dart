import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/error_msg.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/follow/data.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:dio/dio.dart' show Options, Headers;

abstract final class FollowHttp {
  static Future<LoadingState<FollowData>> followings({
    required Account account,
    required int vmid,
    required int pn,
    int ps = 20,
    String orderType = '', // ''=>最近关注，'attention'=>最常访问
  }) async {
    return await Request().requestApi(
      Api.followings,
      kind: ApiCallKind.query,
      decode: (body) => FollowData.fromJson(body['data']),
      errorMessages: errorMsg,
      options: Options(extra: {'account': account}),
      queryParameters: {
        'vmid': vmid,
        'pn': pn,
        'ps': ps,
        'order': 'desc',
        'order_type': orderType,
      },
    );
  }

  static Future<LoadingState<void>> sortFollowTag({
    required Account account,
    required String tagids,
  }) async {
    return await Request().requestApi<void>(
      Api.sortFollowTag,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      queryParameters: {
        'x-bili-device-req-json':
            '{"platform":"web","device":"pc","spmid":"333.1387"}',
      },
      data: {
        'tagids': tagids,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account, 'noRetry': true},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }
}

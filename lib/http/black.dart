import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/blacklist/data.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:dio/dio.dart';

abstract final class BlackHttp {
  static Future<LoadingState<BlackListData>> blackList({
    required int pn,
    int ps = 50,
    required Account account,
  }) async {
    return await Request().requestApi(
      Api.blackLst,
      kind: ApiCallKind.query,
      decode: (body) => BlackListData.fromJson(body['data']),
      queryParameters: {
        'pn': pn,
        'ps': ps,
        're_version': 0,
        'jsonp': 'jsonp',
        'csrf': account.csrf,
      },
      options: Options(extra: {'account': account}),
    );
  }
}

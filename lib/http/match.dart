import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/match/match_info/contest.dart';
import 'package:pili_aurora/models/remote/match/match_info/data.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:dio/dio.dart';

abstract final class MatchHttp {
  static Future<LoadingState<MatchContest?>> matchInfo(
    Object cid, {
    Account? account,
  }) async {
    return await Request().requestApi(
      Api.matchInfo,
      kind: ApiCallKind.query,
      decode: (body) => MatchInfoData.fromJson(body['data']).contest,
      options: account == null ? null : Options(extra: {'account': account}),
      queryParameters: {
        'cid': cid,
        'platform': 2,
      },
    );
  }
}

import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/error_msg.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/follow/data.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:dio/dio.dart';

abstract final class FanHttp {
  static Future<LoadingState<FollowData>> fans({
    required int vmid,
    required int pn,
    int ps = 20,
    String? orderType,
    required Account account,
  }) async {
    return await Request().requestApi(
      Api.fans,
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
}

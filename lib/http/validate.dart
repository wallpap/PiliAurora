import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:dio/dio.dart';

abstract final class ValidateHttp {
  static Future<LoadingState<Map?>> gaiaVgateRegister(
    String vVoucher, {
    required Account account,
  }) async {
    final res = await Request().post(
      Api.gaiaVgateRegister,
      queryParameters: {
        if (account.isLogin) 'csrf': account.csrf,
      },
      data: {
        'v_voucher': vVoucher,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account, 'noRetry': true},
      ),
    );
    if (res.data['code'] == 0) {
      return Success(res.data['data']);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<Map?>> gaiaVgateValidate({
    required Account account,
    required dynamic challenge,
    required dynamic seccode,
    required dynamic token,
    required dynamic validate,
  }) async {
    final res = await Request().post(
      Api.gaiaVgateValidate,
      options: Options(extra: {'account': account, 'noRetry': true}),
      queryParameters: {
        if (account.isLogin) 'csrf': account.csrf,
      },
      data: {
        'challenge': challenge,
        'seccode': seccode,
        'token': token,
        'validate': validate,
      },
    );
    if (res.data['code'] == 0) {
      return Success(res.data['data']);
    } else {
      return Error(res.data['message']);
    }
  }
}

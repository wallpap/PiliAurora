import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/login/gaia_result.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:dio/dio.dart';

abstract final class ValidateHttp {
  static Future<LoadingState<GaiaChallenge>> gaiaVgateRegister(
    String vVoucher, {
    required Account account,
  }) async {
    if (vVoucher.trim().isEmpty) return const Error('验证凭据已失效，请重新发起操作');
    return await Request().requestApi(
      Api.gaiaVgateRegister,
      kind: ApiCallKind.mutation,
      decode: (body) {
        final data = body['data'] as Map<String, dynamic>;
        final geetest = data['geetest'] as Map<String, dynamic>;
        return GaiaChallenge(
          token: _requiredText(data['token'], '验证 token'),
          gt: _requiredText(geetest['gt'], '验证 gt'),
          challenge: _requiredText(geetest['challenge'], '验证 challenge'),
        );
      },
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
  }

  static Future<LoadingState<GaiaVerificationResult>> gaiaVgateValidate({
    required Account account,
    required String challenge,
    required String seccode,
    required String token,
    required String validate,
  }) async {
    if ([
      challenge,
      seccode,
      token,
      validate,
    ].any((value) => value.trim().isEmpty)) {
      return const Error('验证结果不完整，请重新打开验证');
    }
    return await Request().requestApi<GaiaVerificationResult>(
      Api.gaiaVgateValidate,
      kind: ApiCallKind.mutation,
      decode: (body) {
        final data = body['data'] as Map<String, dynamic>;
        return switch (data['is_valid']) {
          1 => GaiaVerified(_requiredText(data['grisk_id'], '验证结果 ID')),
          0 => const GaiaRejected(),
          _ => throw const FormatException('验证响应缺少有效状态'),
        };
      },
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
  }

  static String _requiredText(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$field 缺失或无效');
    }
    return value;
  }
}

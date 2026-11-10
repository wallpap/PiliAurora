import 'dart:convert';

import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/login_devices/data.dart';
import 'package:pili_aurora/models/login/result.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/app_sign.dart';
import 'package:pili_aurora/utils/login_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart';

abstract final class LoginHttp {
  static final String deviceId = LoginUtils.genDeviceId();
  static String get buvid => LoginUtils.buvid;
  static final Map<String, String> headers = {
    'buvid': buvid,
    'env': 'prod',
    'app-key': 'android_hd',
    'user-agent': Constants.userAgent,
    'x-bili-trace-id': Constants.traceId,
    'x-bili-aurora-eid': '',
    'x-bili-aurora-zone': '',
    'bili-http-engine': 'cronet',
    'content-type': 'application/x-www-form-urlencoded; charset=utf-8',
  };

  @pragma('vm:notify-debugger-on-exception')
  static Future<LoadingState<({String authCode, String url})>>
  getHDcode() async {
    final params = {
      // 'local_id': 'Y952A395BB157D305D8A8340FC2AAECECE17',
      'local_id': '0',
      'platform': 'android',
      'mobi_app': 'android_hd',
    };
    AppSign.appSign(params);
    final res = await Request().post(Api.getTVCode, queryParameters: params);

    final result = LoginResult.fromResponse(
      res.data,
      validate: (data) =>
          data['auth_code'] is String &&
          (data['auth_code'] as String).isNotEmpty &&
          data['url'] is String &&
          (data['url'] as String).isNotEmpty,
    );
    return result.isSuccess
        ? Success((
            authCode: result.data['auth_code'] as String,
            url: result.data['url'] as String,
          ))
        : Error(result.message, code: result.code);
  }

  static Future<LoginResult> codePoll(String authCode) async {
    final params = {
      'auth_code': authCode,
      'local_id': '0',
    };
    AppSign.appSign(params);
    final res = await Request().post(
      Api.qrcodePoll,
      queryParameters: params,
      options: Options(extra: {'noRetry': true}),
    );
    return LoginResult.fromResponse(
      res.data,
      validate: (data) =>
          data['cookie_info'] is Map && data['cookie_info']['cookies'] is List,
    );
  }

  static Future<LoginResult> getWebKey() async {
    final res = await Request().get(Api.getWebKey);
    //data: {'disable_rcmd': 0, 'local_id': LoginUtils.generateBuvid()});
    return LoginResult.fromResponse(
      res.data,
      validate: (data) =>
          data['key'] is String &&
          (data['key'] as String).isNotEmpty &&
          (data['hash'] == null || data['hash'] is String),
    );
  }

  static Future<LoginResult> sendSmsCode({
    required Object cid,
    required String tel,
    String? geeChallenge,
    String? geeSeccode,
    String? geeValidate,
    String? recaptchaToken,
  }) async {
    int timestamp = DateTime.now().millisecondsSinceEpoch;
    final data = {
      'build': '2001100',
      'buvid': buvid,
      'c_locale': 'zh_CN',
      'channel': 'master',
      'cid': cid,
      'disable_rcmd': '0',
      'gee_challenge': ?geeChallenge,
      'gee_seccode': ?geeSeccode,
      'gee_validate': ?geeValidate,
      'local_id': buvid,
      // https://chinggg.github.io/post/appre/
      'login_session_id': md5
          .convert(ascii.encode(buvid + timestamp.toString()))
          .toString(),
      'mobi_app': 'android_hd',
      'platform': 'android',
      'recaptcha_token': ?recaptchaToken,
      's_locale': 'zh_CN',
      'statistics': Constants.statistics,
      'tel': tel,
      'ts': (timestamp ~/ 1000).toString(),
    };
    AppSign.appSign(data);

    final res = await Request().post(
      Api.appSmsCode,
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'noRetry': true},
        headers: headers,
      ),
    );

    return LoginResult.fromResponse(
      res.data,
      validate: (data) =>
          data['recaptcha_url'] == '' &&
          data['captcha_key'] is String &&
          (data['captcha_key'] as String).isNotEmpty,
      smsChallenge: true,
    );
  }

  static Future<LoginResult> loginByPwd({
    required String username,
    required String password,
    required String key,
    required String salt,
    String? geeChallenge,
    String? geeSeccode,
    String? geeValidate,
    String? recaptchaToken,
  }) async {
    late final String passwordEncrypted;
    late final String deviceToken;
    try {
      final dynamic publicKey = RSAKeyParser().parse(key);
      final encrypter = Encrypter(RSA(publicKey: publicKey));
      passwordEncrypted = encrypter.encrypt(salt + password).base64;
      deviceToken = encrypter.encrypt(Utils.generateRandomString(16)).base64;
    } catch (_) {
      return LoginResult.failure('登录加密失败，请刷新后重试');
    }

    Map<String, String> data = {
      'bili_local_id': deviceId,
      'build': '2001100',
      'buvid': buvid,
      'c_locale': 'zh_CN',
      'channel': 'master',
      'device': 'phone',
      'device_id': deviceId,
      //'device_meta': '',
      'device_name': 'vivo',
      'device_platform': 'Android14vivo',
      'disable_rcmd': '0',
      'dt': Uri.encodeComponent(deviceToken),
      'from_pv': 'main.homepage.avatar-nologin.all.click',
      'from_url': Uri.encodeComponent('bilibili://pegasus/promo'),
      'gee_challenge': ?geeChallenge,
      'gee_seccode': ?geeSeccode,
      'gee_validate': ?geeValidate,
      'local_id': buvid, //LoginUtils.generateBuvid(),
      'mobi_app': 'android_hd',
      'password': passwordEncrypted,
      'permission': 'ALL',
      'platform': 'android',
      'recaptcha_token': ?recaptchaToken,
      's_locale': 'zh_CN',
      'statistics': Constants.statistics,
      'username': username,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.loginByPwdApi,
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'noRetry': true},
        headers: headers,
        //responseType: ResponseType.plain
      ),
    );

    return LoginResult.fromResponse(
      res.data,
      validate: (data) => data['status'] == 2
          ? _hasRiskVerificationUrl(data['url'])
          : _hasCredentials(data),
    );
  }

  static Future<LoginResult> loginBySms({
    required String captchaKey,
    required String tel,
    required String code,
    required Object cid,
    required String key,
  }) async {
    late final String deviceToken;
    try {
      final dynamic publicKey = RSAKeyParser().parse(key);
      deviceToken = Encrypter(RSA(publicKey: publicKey))
          .encrypt(Utils.generateRandomString(16))
          .base64;
    } catch (_) {
      return LoginResult.failure('登录加密失败，请刷新后重试');
    }
    Map<String, Object> data = {
      'bili_local_id': deviceId,
      'build': '2001100',
      'buvid': buvid,
      'c_locale': 'zh_CN',
      'captcha_key': captchaKey,
      'channel': 'master',
      'cid': cid,
      'code': code,
      'device': 'phone',
      'device_id': deviceId,
      //'device_meta': '',
      'device_name': 'vivo',
      'device_platform': 'Android14vivo',
      // 'device_tourist_id': '',
      'disable_rcmd': '0',
      'dt': Uri.encodeComponent(deviceToken),
      'from_pv': 'main.my-information.my-login.0.click',
      'from_url': Uri.encodeComponent('bilibili://user_center/mine'),
      'local_id': buvid,
      'mobi_app': 'android_hd',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statistics,
      'tel': tel,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.logInByAppSms,
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'noRetry': true},
        headers: headers,
        //responseType: ResponseType.plain
      ),
    );

    return LoginResult.fromResponse(
      res.data,
      validate: _hasCredentials,
    );
  }

  static Future<LoginResult> safeCenterGetInfo({
    required String tmpCode,
  }) async {
    final res = await Request().get(
      Api.safeCenterGetInfo,
      queryParameters: {
        'tmp_code': tmpCode,
      },
    );
    return LoginResult.fromResponse(
      res.data,
      validate: (data) => data['account_info'] is Map,
    );
  }

  static Future<LoginResult> preCapture() async {
    final res = await Request().post(
      Api.preCapture,
      options: Options(extra: {'noRetry': true}),
    );

    return LoginResult.fromResponse(
      res.data,
      validate: (data) =>
          data['gee_gt'] is String &&
          data['gee_challenge'] is String &&
          data['recaptcha_token'] is String,
    );
  }

  static Future<LoginResult> safeCenterSmsCode({
    String? smsType,
    required String tmpCode,
    String? geeChallenge,
    String? geeSeccode,
    String? geeValidate,
    String? recaptchaToken,
    required String refererUrl,
  }) async {
    Map<String, String> data = {
      'disable_rcmd': '0',
      'sms_type': smsType ?? 'loginTelCheck',
      'tmp_code': tmpCode,
      'gee_challenge': ?geeChallenge,
      'gee_seccode': ?geeSeccode,
      'gee_validate': ?geeValidate,
      'recaptcha_token': ?recaptchaToken,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.safeCenterSmsCode,
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'noRetry': true},
        headers: {
          "Referer": refererUrl,
        },
      ),
    );

    return LoginResult.fromResponse(
      res.data,
      validate: (data) =>
          data['captcha_key'] is String &&
          (data['captcha_key'] as String).isNotEmpty,
    );
  }

  static Future<LoginResult> safeCenterSmsVerify({
    String? type,
    required String code,
    required String tmpCode,
    required String requestId,
    required String source,
    required String captchaKey,
    required String refererUrl,
  }) async {
    Map<String, String> data = {
      'type': type ?? 'loginTelCheck',
      'code': code,
      'tmp_code': tmpCode,
      'request_id': requestId,
      'source': source,
      'captcha_key': captchaKey,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.safeCenterSmsVerify,
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'noRetry': true},
        headers: {
          "Referer": refererUrl,
        },
      ),
    );

    return LoginResult.fromResponse(
      res.data,
      validate: (data) =>
          data['code'] is String && (data['code'] as String).isNotEmpty,
    );
  }

  static Future<LoginResult> oauth2AccessToken({
    required String code,
  }) async {
    final Map<String, String> data = {
      'build': '2001100',
      'buvid': buvid,
      // 'c_locale': 'zh_CN',
      // 'channel': 'master',
      'code': code,
      // 'device': 'phone',
      // 'device_id': deviceId,
      // 'device_name': 'vivo',
      // 'device_platform': 'Android14vivo',
      'disable_rcmd': '0',
      'grant_type': 'authorization_code',
      'local_id': buvid,
      'mobi_app': 'android_hd',
      'platform': 'android',
      // 's_locale': 'zh_CN',
      // 'statistics': Constants.statistics,
    };
    AppSign.appSign(data);
    final res = await Request().post(
      Api.oauth2AccessToken,
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'noRetry': true},
        headers: headers,
      ),
    );

    return LoginResult.fromResponse(
      res.data,
      validate: _hasCredentials,
    );
  }

  static bool _hasCredentials(Map<String, dynamic> data) =>
      data['token_info'] is Map &&
      data['cookie_info'] is Map &&
      data['cookie_info']['cookies'] is List;

  static bool _hasRiskVerificationUrl(Object? value) {
    final uri = value is String ? Uri.tryParse(value) : null;
    return uri != null &&
        const ['tmp_token', 'request_id', 'source'].every(
          (key) => uri.queryParameters[key]?.isNotEmpty == true,
        );
  }

  static Future<LoadingState<void>> logout(LoginAccount account) {
    return Request().requestApi<void>(
      Api.logout,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {'biliCSRF': account.csrf},
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
  }

  static Future<LoadingState<LoginDevicesData>> loginDevices({
    required Account account,
  }) {
    final buvid = LoginUtils.buvid;
    final params = {
      'local_id': buvid,
      'buvid': buvid,
      'device_name': 'android',
      'device_platform': 'android',
      'csrf': account.csrf,
      'mobi_app': 'android_hd',
      'platform': 'android',
      'access_key': account.accessKey,
      'statistics': Constants.statistics,
    };
    AppSign.appSign(params);
    return Request().requestApi<LoginDevicesData>(
      Api.loginDevices,
      kind: ApiCallKind.query,
      decode: (body) => LoginDevicesData.fromJson(body['data']),
      queryParameters: params,
      options: Options(extra: {'account': account}),
    );
  }
}

// edit from package:dio_cookie_manager
import 'dart:io';

import 'package:pili_aurora/services/diagnostics/redact.dart';
import 'package:pili_aurora/services/logger.dart';

import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/request_failure_policy.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/accounts/api_type.dart';
import 'package:pili_aurora/utils/app_sign.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

final _setCookieReg = RegExp('(?<=)(,)(?=[^;]+?=)');

/// 服务端已经响应，但本地 Cookie 或账号持久化失败；不能因此重放远端写操作。
class AccountCookiePersistenceException implements Exception {
  const AccountCookiePersistenceException(this.cause);
  final Object cause;

  @override
  String toString() => '账号状态保存失败，请检查存储后重试';
}

class AccountManager extends Interceptor {
  AccountManager();

  static String blockServer = Pref.blockServer;

  static String getCookies(List<Cookie> cookies) {
    // Sort cookies by path (longer path first).
    cookies.sort((a, b) {
      if (a.path == null && b.path == null) {
        return 0;
      } else if (a.path == null) {
        return -1;
      } else if (b.path == null) {
        return 1;
      } else {
        return b.path!.length.compareTo(a.path!.length);
      }
    });
    return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.path;

    final account = _bindRequestAccount(options);

    if (account is NoAccount || _skipCookie(path)) return handler.next(options);

    if (!account.isLogin && path == Api.heartBeat) {
      return handler.reject(
        DioException.requestCancelled(requestOptions: options, reason: null),
        false,
      );
    }

    final isApp = path.startsWith(HttpString.appBaseUrl);

    if (isApp && options.responseType == ResponseType.bytes) {
      options.headers.addAll(account.grpcHeaders);
      return handler.next(options);
    }

    options.headers
      ..addAll(account.headers)
      ..['referer'] ??= HttpString.baseUrl;

    // app端不需要管理cookie
    if (isApp) {
      // if (kDebugMode) debugPrint('is app: ${options.path}');
      final dataPtr = (options.method == 'POST' && options.data is Map
          ? (options.data as Map).cast<String, dynamic>()
          : options.queryParameters);
      if (dataPtr.isNotEmpty) {
        if (!account.accessKey.isNullOrEmpty) {
          dataPtr['access_key'] = account.accessKey!;
        }
        AppSign.appSign(dataPtr..remove('sign'));
        // if (kDebugMode) debugPrint(dataPtr.toString());
      }
      return handler.next(options);
    } else {
      account.cookieJar
          .loadForRequest(options.uri)
          .then((cookies) {
            final previousCookies =
                options.headers[HttpHeaders.cookieHeader] as String?;
            final newCookies = getCookies([
              ...?previousCookies
                  ?.split(';')
                  .where((e) => e.isNotEmpty)
                  .map(Cookie.fromSetCookieValue),
              ...cookies,
            ]);
            options.headers[HttpHeaders.cookieHeader] = newCookies.isNotEmpty
                ? newCookies
                : '';
            handler.next(options);
          })
          .catchError((Object e, StackTrace s) {
            final err = DioException(
              requestOptions: options,
              error: e,
              stackTrace: s,
            );
            handler.reject(err, true);
          });
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (_boundRequestAccount(response.requestOptions) case final account?) {
      _saveCookies(
        account,
        response,
      ).then(
        (_) => handler.next(response),
        onError: (Object e, StackTrace s) => handler.reject(
          DioException(
            requestOptions: response.requestOptions,
            response: response,
            error: AccountCookiePersistenceException(e),
            stackTrace: s,
          ),
          true,
        ),
      );
    } else {
      return handler.next(response);
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    if (options.responseType == ResponseType.stream) {
      return handler.next(err);
    }

    if (options.method != 'POST') toast(err);

    if (err.error is AccountCookiePersistenceException) {
      return handler.next(err);
    }

    if (err.response case final res?) {
      if (_boundRequestAccount(options) case final account?) {
        _saveCookies(account, res).then(
          (_) => handler.next(err),
          onError: (Object e, StackTrace s) {
            // Cookie 保存是次要失败，保留原始 HTTP 状态与请求错误供调用方判断。
            logger.w('保存错误响应中的账号状态失败', error: e.runtimeType, stackTrace: s);
            handler.next(err);
          },
        );
        return;
      }
    }
    return handler.next(err);
  }

  static void toast(DioException err) {
    if (isExpectedHttpFailure(err)) return;
    final url = DiagnosticRedactor.text(err.requestOptions.uri);
    final status = err.response?.statusCode;
    dioError(err).then(
      (res) => SmartDialog.showToast(
        '$res\n${err.requestOptions.method} $url'
        '${status == null ? '' : ' (HTTP $status)'}',
      ),
    );
  }

  static Future<void> _saveCookies(Account account, Response response) async {
    final setCookies = response.headers[HttpHeaders.setCookieHeader];
    if (setCookies == null || setCookies.isEmpty) {
      return;
    }
    final List<Cookie> cookies = setCookies
        .map((str) => str.split(_setCookieReg))
        .expand((cookie) => cookie)
        .where((cookie) => cookie.isNotEmpty)
        .map(Cookie.fromSetCookieValue)
        .toList();
    final statusCode = response.statusCode ?? 0;
    final locations = response.headers[HttpHeaders.locationHeader] ?? const [];
    final isRedirectRequest = statusCode >= 300 && statusCode < 400;
    final originalUri = response.requestOptions.uri;
    final realUri = originalUri.resolveUri(response.realUri);
    await account.cookieJar.saveFromResponse(realUri, cookies);
    if (isRedirectRequest && locations.isNotEmpty) {
      final originalUri = response.realUri;
      await Future.wait(
        locations.map(
          (location) => account.cookieJar.saveFromResponse(
            // Resolves the location based on the current Uri.
            originalUri.resolve(location),
            cookies,
          ),
        ),
      );
    }
    await account.onChange();
  }

  static bool _skipCookie(String path) {
    return path.startsWith(blockServer) ||
        path.contains('hdslb.com') ||
        path.contains('biliimg.com');
  }

  static Account _findAccount(String path) => ApiType.loginApi.contains(path)
      ? AnonymousAccount()
      : Accounts.get(
          AccountType.values.firstWhere(
            (i) => ApiType.apiTypeSet[i]?.contains(path) == true,
            orElse: () => AccountType.main,
          ),
        );

  static Account _bindRequestAccount(RequestOptions options) {
    assert(options.extra['account'] is Account?);
    return options.extra['account'] ??= _findAccount(options.path);
  }

  static Account? _boundRequestAccount(RequestOptions options) {
    final path = options.path;
    final account = options.extra['account'] as Account;
    if (account is NoAccount ||
        path.startsWith(HttpString.appBaseUrl) ||
        _skipCookie(path)) {
      return null;
    }
    return account;
  }

  static Future<String> dioError(DioException error) async {
    if (error.error case AccountCookiePersistenceException failure) {
      return failure.toString();
    }
    switch (error.type) {
      case .badCertificate:
        return '证书有误！';
      case .badResponse:
        return '服务器异常，请稍后重试！';
      case .cancel:
        return '请求已被取消，请重新请求';
      case .connectionError:
        return '连接错误，请检查网络设置';
      case .connectionTimeout:
        return '网络连接超时，请检查网络设置';
      case .receiveTimeout:
        return '响应超时，请稍后重试！';
      case .sendTimeout:
        return '发送请求超时，请检查网络设置';
      case .transformTimeout:
        return '转换响应数据超时！';
      case .unknown:
        String desc;
        try {
          desc = PlatformUtils.isMobile
              ? (await Connectivity().checkConnectivity()).first.desc
              : '';
        } catch (_) {
          desc = '';
        }
        return '$desc网络异常 ${DiagnosticRedactor.text(error.error)}';
    }
  }
}

extension _ConnectivityResultExt on ConnectivityResult {
  String get desc => const ['蓝牙', 'Wi-Fi', '局域', '流量', '无', '代理', '其他'][index];
}

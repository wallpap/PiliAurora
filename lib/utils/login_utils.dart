import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/services/webview_environment.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart' show Digest;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as web;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

abstract final class LoginUtils {
  static Future<void> _webCookieTail = Future.value();

  // 不同账号的原生写入串行交接，避免迟到的旧 Cookie 覆盖新登录。
  static Future<T> _queueWebCookies<T>(Future<T> Function() action) {
    final result = _webCookieTail.then((_) => action());
    // 队列可以继续；调用方仍从 result 收到原始失败。
    _webCookieTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// 返回 false 表示切号后失效；原生拒绝或异常通过 Future 返回。
  static Future<bool> setWebCookie([Account? account]) {
    final owner = account ?? Accounts.main;
    return _queueWebCookies(() async {
      if (!identical(owner, Accounts.main)) return false;
      final cookies = owner.cookieJar.toList();
      final webManager = web.CookieManager.instance(
        webViewEnvironment: AppWebViewEnvironment.instance,
      );
      final results = await Future.wait(
        cookies.map(
          (cookie) => webManager.setCookie(
            url: web.WebUri(
              '${Platform.isWindows ? 'https://' : ''}${cookie.domain}',
            ),
            name: cookie.name,
            value: cookie.value,
            path: cookie.path ?? '/',
            domain: cookie.domain,
            isSecure: cookie.secure,
            isHttpOnly: cookie.httpOnly,
          ),
        ),
      );
      if (results.any((success) => !success)) {
        throw const Error('网页 Cookie 同步失败，请重试');
      }
      return identical(owner, Accounts.main);
    });
  }

  static Future<void> onLoginMain() async {
    final account = Accounts.main;
    final res = await UserHttp.userInfo(account: account);
    if (!identical(account, Accounts.main)) return;
    if (res case Success(:final response)) {
      GlobalData().coins = response.money;
      unawaited(
        setWebCookie(account).catchError((Object error, StackTrace stackTrace) {
          logger.w(
            '登录后的网页 Cookie 同步失败',
            error: error.runtimeType,
            stackTrace: stackTrace,
          );
          return false;
        }),
      );
      unawaited(
        RequestUtils.syncHistoryStatus().catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          logger.w(
            '登录后的历史状态同步失败',
            error: error.runtimeType,
            stackTrace: stackTrace,
          );
        }),
      );
      if (response.isLogin == true) {
        final accountService = Get.find<AccountService>()
          ..face.value = response.face!;

        if (accountService.isLogin.value) {
          accountService.isLogin.refresh();
        } else {
          accountService.isLogin.value = true;
        }

        SmartDialog.showToast('main登录成功');
        if (response != Pref.userInfoCache) {
          await GStorage.userInfo.put('userInfoCache', response);
        }
      }
    } else {
      // 获取用户信息失败
      final errMsg = res.toString();
      if (errMsg == '账号未登录') {
        await Accounts.deleteAll({account});
        SmartDialog.showNotify(
          msg: '登录失败，请检查cookie是否正确，$errMsg',
          notifyType: .warning,
        );
      } else {
        SmartDialog.showToast(errMsg);
      }
    }
  }

  static Future<void> onLogoutMain() {
    final owner = Accounts.main;
    Get.find<AccountService>()
      ..face.value = ''
      ..isLogin.value = false;

    return Future.wait([
      _queueWebCookies(() async {
        if (!identical(owner, Accounts.main)) return;
        final cleared = await web.CookieManager.instance(
          webViewEnvironment: AppWebViewEnvironment.instance,
        ).deleteAllCookies();
        if (!cleared) throw const Error('网页 Cookie 清理失败，请重试');
      }),
      GStorage.userInfo.delete('userInfoCache'),
    ]);
  }

  static String generateBuvid() {
    final md5Str = Digest(
      List.generate(16, (_) => Utils.random.nextInt(256)),
    ).toString();
    return 'XY${md5Str[2]}${md5Str[12]}${md5Str[22]}$md5Str';
  }

  static final buvid = Pref.buvid;

  // static String getUUID() {
  //   return const Uuid().v4().replaceAll('-', '');
  // }

  static String genDeviceId() {
    // https://github.com/bilive/bilive_client/blob/2873de0532c54832f5464a4c57325ad9af8b8698/bilive/lib/app_client.ts#L62
    final time = DateTime.now();

    final List<int> bytes = [
      ...Iterable.generate(16, (_) => Utils.random.nextInt(256)),
      _dec2bcd(time.year ~/ 100),
      _dec2bcd(time.year % 100),
      _dec2bcd(time.month),
      _dec2bcd(time.day),
      _dec2bcd(time.hour),
      _dec2bcd(time.minute),
      _dec2bcd(time.second),
      ...Iterable.generate(8, (_) => Utils.random.nextInt(256)),
    ];
    final check = (bytes.sum & 0xFF).toRadixString(16).padLeft(2, '0');

    return Digest(bytes).toString() + check;
  }

  static int _dec2bcd(int dec) {
    assert(0 <= dec && dec < 100);
    return ((dec ~/ 10) << 4) | (dec % 10);
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/login.dart';
import 'package:pili_aurora/models/remote/login_devices/device.dart';
import 'package:pili_aurora/services/account_providers.dart';

final loginDevicesProvider = FutureProvider<List<LoginDevice>>(
  (ref) async {
    final account = ref.watch(mainAccountProvider);
    if (!account.isLogin) throw const Error('账号未登录');
    try {
      final result = await LoginHttp.loginDevices(account: account);
      return switch (result) {
        Success(:final response) => List.unmodifiable(
          response.devices ?? const <LoginDevice>[],
        ),
        Error() => throw result,
        _ => throw const Error('加载失败，请重试'),
      };
    } on Error {
      rethrow;
    } catch (_) {
      throw const Error('加载失败，请重试');
    }
  },
  isAutoDispose: true,
  retry: (_, _) => null,
);

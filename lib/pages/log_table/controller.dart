import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/models/remote/coin_log/list.dart';
import 'package:pili_aurora/models/remote/login_log/list.dart';
import 'package:pili_aurora/services/account_providers.dart';

typedef LogRow = List<(int, String)>;

enum LogType {
  login('登录记录', [(3, '时间'), (2, '变化'), (3, '地理位置')]),
  coin('硬币记录', [(3, '时间'), (1, '变化'), (4, '原因')]),
  exp('经验记录', [(2, '时间'), (1, '变化'), (2, '原因')]);

  const LogType(this.title, this.header);
  final String title;
  final LogRow header;

  LogRow loginRow(LoginLogItem item) => [
    (3, item.timeAt),
    (2, item.ip),
    (3, item.geo),
  ];
  LogRow coinRow(CoinLogItem item) => switch (this) {
    LogType.coin => [(3, item.time), (1, item.delta), (4, item.reason)],
    LogType.exp => [(2, item.time), (1, item.delta), (2, item.reason)],
    LogType.login => throw StateError('登录记录不包含硬币条目'),
  };
}

final logTableProvider = FutureProvider.family<List<LogRow>, LogType>(
  (ref, type) async {
    final account = ref.watch(mainAccountProvider);
    if (!account.isLogin) throw const Error('账号未登录');
    try {
      switch (type) {
        case LogType.login:
          final result = await UserHttp.loginLog(account: account);
          return switch (result) {
            Success(:final response) => List.unmodifiable(
              (response.list ?? const []).map(
                (item) => List<(int, String)>.unmodifiable(
                  type.loginRow(item),
                ),
              ),
            ),
            Error() => throw result,
            _ => throw const Error('加载失败，请重试'),
          };
        case LogType.coin:
        case LogType.exp:
          final result = type == LogType.coin
              ? await UserHttp.coinLog(account: account)
              : await UserHttp.expLog(account: account);
          return switch (result) {
            Success(:final response) => List.unmodifiable(
              (response.list ?? const []).map(
                (item) => List<(int, String)>.unmodifiable(
                  type.coinRow(item),
                ),
              ),
            ),
            Error() => throw result,
            _ => throw const Error('加载失败，请重试'),
          };
      }
    } on Error {
      rethrow;
    } catch (_) {
      throw const Error('加载失败，请重试');
    }
  },
  isAutoDispose: true,
  retry: (_, _) => null,
);

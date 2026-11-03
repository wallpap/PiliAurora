import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/msg/msg_unread_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

typedef AccountSessionKey = ({int mid, int generation});

enum MessagingChangeKind {
  sessions,
  conversation,
  conversationRead,
  unread,
  settings,
}

class MessagingChange {
  const MessagingChange(this.kind, {this.talkerId, this.readType});
  final MessagingChangeKind kind;
  final int? talkerId;
  final MsgUnReadType? readType;
}

const messagingUnknownResultCode = -10001;
const messagingInactiveCode = -10002;

/// 每次主账号切换创建独立所有者；远端操作完成后仍须检查此所有者是否有效。
class MessagingSession {
  MessagingSession({
    required this.account,
    required this.key,
    this.isCurrent,
  });

  final Account account;
  final AccountSessionKey key;
  final bool Function()? isCurrent;
  final _changes = StreamController<MessagingChange>.broadcast(sync: true);
  final Map<Object, Object> _resources = {};
  final List<VoidCallback> _disposers = [];
  bool _disposed = false;

  bool get isActive =>
      !_disposed && account.isLogin && (isCurrent?.call() ?? true);
  Stream<MessagingChange> get changes => _changes.stream;

  T resource<T extends Object>(
    Object key,
    T Function() create,
    void Function(T) dispose,
  ) {
    return _resources.putIfAbsent(key, () {
      final value = create();
      _disposers.add(() => dispose(value));
      return value;
    }) as T;
  }

  Future<LoadingState<T>> run<T>(
    Future<LoadingState<T>> Function(Account) request,
  ) async {
    if (!isActive) return const Error('账号已切换或未登录', code: messagingInactiveCode);
    LoadingState<T> result;
    try {
      result = await request(account);
    } on DioException catch (error) {
      result = switch (error.type) {
        DioExceptionType.cancel => const Error('请求已取消'),
        DioExceptionType.badResponse => const Error('服务器请求失败'),
        _ => const Error('请求结果待确认，请刷新后核对', code: messagingUnknownResultCode),
      };
    } catch (_) {
      result = const Error('请求失败');
    }
    return isActive
        ? result
        : const Error('账号已切换', code: messagingInactiveCode);
  }

  void notifyChanged(
    MessagingChangeKind kind, {
    int? talkerId,
    MsgUnReadType? readType,
  }) {
    if (isActive) {
      _changes.add(
        MessagingChange(kind, talkerId: talkerId, readType: readType),
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final dispose in _disposers.reversed) {
      dispose();
    }
    _disposers.clear();
    _resources.clear();
    unawaited(_changes.close());
  }
}

/// Get 路由与 Riverpod 订阅共同取得这一份账号 Session。
class Messaging {
  Messaging._() {
    _account = Accounts.main;
    current = ValueNotifier(_create(_account));
  }

  static Messaging? _instance;
  static Messaging get instance => _instance ??= Messaging._();
  static void onAccountChanged() => _instance?._replace(Accounts.main);

  late Account _account;
  int _generation = 0;
  late final ValueNotifier<MessagingSession> current;

  MessagingSession _create(Account account) => MessagingSession(
    account: account,
    key: (mid: account.isLogin ? account.mid : 0, generation: ++_generation),
    isCurrent: () => identical(Accounts.main, account),
  );

  MessagingSession get session {
    if (!identical(_account, Accounts.main)) _replace(Accounts.main);
    return current.value;
  }

  void _replace(Account account) {
    current.value.dispose();
    _account = account;
    current.value = _create(account);
  }
}

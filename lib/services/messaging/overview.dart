import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/grpc/im.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/msg.dart';
import 'package:pili_aurora/models/common/msg/msg_unread_type.dart';
import 'package:pili_aurora/services/messaging/providers.dart';
import 'package:pili_aurora/services/messaging/session.dart';

class UnreadSnapshot {
  UnreadSnapshot({
    Map<MsgUnReadType, int?> counts = const {},
    Map<MsgUnReadType, String> errors = const {},
    this.refreshing = false,
    this.updatedAt,
  }) : counts = Map.unmodifiable({
         for (final type in MsgUnReadType.values) type: counts[type],
       }),
       errors = Map.unmodifiable(errors);
  final Map<MsgUnReadType, int?> counts;
  final Map<MsgUnReadType, String> errors;
  final bool refreshing;
  final DateTime? updatedAt;

  int? total(Set<MsgUnReadType> types, {bool disableLike = false}) {
    int total = 0;
    bool known = false;
    for (final type in types) {
      if (disableLike && type == MsgUnReadType.like) continue;
      if (counts[type] case final count?) {
        total += count;
        known = true;
      }
    }
    return known ? total : null;
  }
}

class UnreadQueryResult {
  const UnreadQueryResult(this.counts, {this.errors = const {}});
  final Map<MsgUnReadType, int?> counts;
  final Map<MsgUnReadType, String> errors;
}

typedef UnreadQuery = Future<UnreadQueryResult> Function();

/// 概览归账号所有；阅读成功废弃旧查询，后续结果统一供所有角标订阅。
class UnreadOverview {
  UnreadOverview(this.session, {this.query}) {
    _subscription = session.changes.listen((change) {
      if (change.kind == MessagingChangeKind.unread) {
        if (change.readType case final type?) {
          // 阅读成功就是本地确认；立即重查可能拿到远端尚未收敛的旧数值。
          _generation++;
          _pending = null;
          state.value = UnreadSnapshot(
            counts: {...state.value.counts, type: 0},
            errors: {...state.value.errors}..remove(type),
            updatedAt: DateTime.now(),
          );
          return;
        }
        invalidate();
      }
    });
  }
  final MessagingSession session;
  final UnreadQuery? query;
  final state = ValueNotifier(UnreadSnapshot());
  StreamSubscription<MessagingChange>? _subscription;
  Future<void>? _pending;
  int _generation = 0;
  bool _disposed = false;

  Future<void> refresh() {
    if (_disposed || !session.isActive) return Future.value();
    return _pending ??= _refresh(++_generation);
  }

  Future<void> _refresh(int generation) async {
    // 延后一个微任务，确保 pending 在同步失败前已经登记。
    await Future<void>.value();
    if (!_valid(generation)) return;
    state.value = UnreadSnapshot(
      counts: state.value.counts,
      errors: state.value.errors,
      updatedAt: state.value.updatedAt,
      refreshing: true,
    );
    try {
      final result = await (query?.call() ?? _fetch());
      if (!_valid(generation)) return;
      final counts = Map<MsgUnReadType, int?>.of(state.value.counts);
      for (final entry in result.counts.entries) {
        if (!result.errors.containsKey(entry.key)) {
          counts[entry.key] = entry.value;
        }
      }
      state.value = UnreadSnapshot(
        counts: counts,
        errors: result.errors,
        updatedAt: DateTime.now(),
      );
    } catch (_) {
      if (_valid(generation)) {
        state.value = UnreadSnapshot(
          counts: state.value.counts,
          errors: {for (final type in MsgUnReadType.values) type: '未读查询失败'},
          updatedAt: state.value.updatedAt,
        );
      }
    } finally {
      if (generation == _generation) _pending = null;
    }
  }

  bool _valid(int generation) =>
      !_disposed && session.isActive && generation == _generation;

  void invalidate() {
    if (_disposed) return;
    _generation++;
    _pending = null;
    unawaited(refresh());
  }

  Future<UnreadQueryResult> _fetch() async {
    final counts = <MsgUnReadType, int?>{};
    final errors = <MsgUnReadType, String>{};
    await Future.wait([
      () async {
        final result = await session.run(
          (account) => MsgHttp.msgUnread(account: account),
        );
        if (result case Success(:final response)) {
          counts[MsgUnReadType.pm] = response.hasAccessibleCounts
              ? response.followUnread +
                    response.unfollowUnread +
                    response.bizMsgFollowUnread +
                    response.bizMsgUnfollowUnread +
                    response.unfollowPushMsg +
                    response.customUnread
              : null;
        } else {
          errors[MsgUnReadType.pm] = result.toString();
        }
      }(),
      () async {
        final result = await session.run(
          (account) => ImGrpc.getTotalUnread(unreadType: 2, account: account),
        );
        final fields = {
          MsgUnReadType.reply: 'reply',
          MsgUnReadType.at: 'at',
          MsgUnReadType.like: 'like',
          MsgUnReadType.sysMsg: 'sys_msg',
        };
        if (result case Success(:final response)) {
          for (final entry in fields.entries) {
            final count = response.msgFeedUnread.unread[entry.value]?.toInt();
            counts[entry.key] = count?.clamp(0, 0x7fffffff);
          }
        } else {
          for (final type in fields.keys) {
            errors[type] = result.toString();
          }
        }
      }(),
    ]);
    return UnreadQueryResult(counts, errors: errors);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    unawaited(_subscription?.cancel());
    state.dispose();
  }
}

UnreadOverview overviewFor(MessagingSession session) => session.resource(
  UnreadOverview,
  () => UnreadOverview(session),
  (overview) => overview.dispose(),
);

final overviewHandleProvider = Provider<UnreadOverview>(
  (ref) => overviewFor(ref.watch(messagingSessionProvider)),
);
final overviewProvider = snapshotProvider(
  (ref) => ref.watch(overviewHandleProvider).state,
);

import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/danmaku_block.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/dm_block_type.dart';
import 'package:pili_aurora/models/user/danmaku_block.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

final danmakuBlockProvider =
    NotifierProvider<DanmakuBlockNotifier, DanmakuBlockState>(
      DanmakuBlockNotifier.new,
      isAutoDispose: true,
    );

class DanmakuBlockState {
  DanmakuBlockState({
    LoadingState<List<List<SimpleRule>>>? rules,
    this.isSaving = false,
    this.notice,
  }) : rules = rules ?? LoadingState.loading();

  final LoadingState<List<List<SimpleRule>>> rules;
  final bool isSaving;
  final String? notice;
}

class DanmakuBlockNotifier extends Notifier<DanmakuBlockState> {
  late Account _account;
  Object? _owner;
  int _queryVersion = 0;

  @override
  DanmakuBlockState build() {
    _account = ref.watch(mainAccountProvider);
    final owner = _owner = Object();
    ref.onDispose(() {
      if (identical(_owner, owner)) _owner = null;
    });
    if (!_account.isLogin) {
      return DanmakuBlockState(rules: const Error('账号未登录'));
    }
    unawaited(
      Future.microtask(() {
        if (_isCurrent(owner)) return reload();
      }),
    );
    return DanmakuBlockState();
  }

  bool _isCurrent(Object? owner) =>
      ref.mounted &&
      owner != null &&
      identical(owner, _owner) &&
      identical(_account, Accounts.main);

  Future<void> reload() async {
    final owner = _owner;
    if (!_isCurrent(owner) || !_account.isLogin || state.isSaving) return;
    final account = _account;
    final version = ++_queryVersion;
    state = DanmakuBlockState();
    LoadingState<DanmakuBlockDataModel> result;
    try {
      result = await DanmakuFilterHttp.danmakuFilter(account: account);
    } catch (_) {
      result = const Error('加载失败，请重试');
    }
    if (!_isCurrent(owner) || version != _queryVersion) return;
    state = switch (result) {
      Success(:final response) => DanmakuBlockState(
        rules: Success(
          List.unmodifiable([
            List<SimpleRule>.unmodifiable(response.rule),
            List<SimpleRule>.unmodifiable(response.rule1),
            List<SimpleRule>.unmodifiable(response.rule2),
          ]),
        ),
        notice: response.toast,
      ),
      Error() => DanmakuBlockState(rules: result),
      _ => DanmakuBlockState(rules: const Error('加载失败，请重试')),
    };
  }

  Future<LoadingState<void>> remove(DmBlockType type, int id) =>
      _write(type, removeId: id);

  /// 编辑作为一次串行操作；删除失败时不再添加替代规则。
  Future<LoadingState<void>> save(
    DmBlockType type,
    String filter, {
    int? replaceId,
  }) async {
    if (filter.isEmpty) return const Error('输入内容不能为空');
    if (type == DmBlockType.regex) {
      try {
        RegExp(filter);
      } on FormatException {
        return const Error('正则表达式无效');
      }
    } else if (type == DmBlockType.uid) {
      if (!RegExp(r'^\d+$').hasMatch(filter)) return const Error('请输入有效的用户UID');
      filter = getCrc32(ascii.encode(filter), 0).toRadixString(16);
    }
    return _write(type, filter: filter, removeId: replaceId);
  }

  Future<LoadingState<void>> _write(
    DmBlockType type, {
    String? filter,
    int? removeId,
  }) async {
    final owner = _owner;
    if (!_isCurrent(owner)) return const Error('账号已切换或页面已关闭');
    final current = state.rules.dataOrNull;
    if (current == null || state.isSaving) return const Error('请等待当前操作完成');
    final account = _account;
    state = DanmakuBlockState(rules: state.rules, isSaving: true);
    try {
      if (removeId != null) {
        final result = await DanmakuFilterHttp.danmakuFilterDel(
          ids: removeId,
          account: account,
        );
        if (!_isCurrent(owner)) return const Error('账号已切换或页面已关闭');
        if (!result.isSuccess) return result;
        _publish(
          type,
          current[type.index].where((rule) => rule.id != removeId),
        );
      }
      if (filter != null) {
        final result = await DanmakuFilterHttp.danmakuFilterAdd(
          filter: filter,
          type: type.index,
          account: account,
        );
        if (!_isCurrent(owner)) return const Error('账号已切换或页面已关闭');
        if (result case Success(:final response)) {
          _publish(type, [
            ...state.rules.data[type.index].where(
              (rule) => rule.id != response.id,
            ),
            response,
          ]);
        } else {
          return Error(
            removeId == null ? result.toString() : '原规则已删除，添加失败：$result',
          );
        }
      }
      return const Success(null);
    } catch (_) {
      return const Error('操作未完成，请刷新规则后核对');
    } finally {
      if (_isCurrent(owner)) state = DanmakuBlockState(rules: state.rules);
    }
  }

  void _publish(DmBlockType type, Iterable<SimpleRule> rules) {
    final lists = [...state.rules.data];
    lists[type.index] = List.unmodifiable(rules);
    state = DanmakuBlockState(
      rules: Success(List.unmodifiable(lists)),
      isSaving: true,
    );
  }
}

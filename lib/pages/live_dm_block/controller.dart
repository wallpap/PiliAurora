import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/live.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/live/live_dm_block/shield_user_list.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';

typedef LiveBlockRulesChanged = void Function(
  List<String> keywords,
  Set<int> uids,
);

class LiveBlockState {
  LiveBlockState({
    required Iterable<String> keywords,
    required Iterable<ShieldUserList> users,
    this.saving = false,
    Object? source,
  }) : keywords = List.unmodifiable(keywords),
       users = List.unmodifiable(users),
       source = source ?? Object();
  final List<String> keywords;
  final List<ShieldUserList> users;
  final bool saving;
  final Object source;
  LiveBlockState copy({
    Iterable<String>? keywords,
    Iterable<ShieldUserList>? users,
    bool saving = false,
  }) => LiveBlockState(
    keywords: keywords ?? this.keywords,
    users: users ?? this.users,
    saving: saving,
    source: source,
  );
}

final liveBlockProvider = AsyncNotifierProvider.autoDispose
    .family<LiveBlockNotifier, LiveBlockState, String>(
      LiveBlockNotifier.new,
      retry: (_, _) => null,
    );

class LiveBlockNotifier extends AsyncNotifier<LiveBlockState> {
  LiveBlockNotifier(this.roomId);
  final String roomId;
  @override
  Future<LiveBlockState> build() async {
    final account = ref.watch(mainAccountProvider);
    if (!account.isLogin) throw const Error('账号未登录');
    final result = await LiveHttp.getLiveInfoByUser(roomId, account: account);
    final rules = result.data;
    if (rules == null) throw const Error('屏蔽规则响应不完整');
    return LiveBlockState(
      keywords: rules.keywordList ?? [],
      users: rules.shieldUserList ?? [],
    );
  }

  Future<LoadingState<void>> change({
    required Object source,
    required bool keyword,
    required String value,
    bool remove = false,
  }) async {
    final before = state.value;
    final owner = ref;
    final account = owner.read(mainAccountProvider);
    if (state.isLoading ||
        state.hasError ||
        before == null ||
        before.saving ||
        !identical(before.source, source) ||
        !identical(account, Accounts.main)) {
      return const Error('规则或账号已更新，请重新操作');
    }
    value = value.trim();
    if (value.isEmpty || (!keyword && (int.tryParse(value) ?? 0) <= 0)) {
      return const Error('请输入有效的屏蔽内容');
    }
    final exists = keyword
        ? before.keywords.contains(value)
        : before.users.any((e) => e.uid.toString() == value);
    if (exists != remove) return const Success(null);
    state = AsyncData(before.copy(saving: true));
    bool current() => owner.mounted && identical(account, Accounts.main);
    try {
      late LoadingState<dynamic> result;
      if (keyword) {
        result = remove
            ? await LiveHttp.delShieldKeyword(keyword: value, account: account)
            : await LiveHttp.addShieldKeyword(keyword: value, account: account);
      } else {
        result = await LiveHttp.liveShieldUser(
          uid: value,
          roomid: roomId,
          type: remove ? 0 : 1,
          account: account,
        );
      }
      if (!current()) return const Error('账号已切换或页面已关闭');
      if (!result.isSuccess) {
        state = AsyncData(before);
        return Error(result.toString());
      }
      state = AsyncData(
        LiveBlockState(
          keywords: keyword
              ? (remove
                    ? before.keywords.where((e) => e != value)
                    : [value, ...before.keywords])
              : before.keywords,
          users: !keyword
              ? (remove
                    ? before.users.where((e) => e.uid.toString() != value)
                    : [result.data as ShieldUserList, ...before.users])
              : before.users,
        ),
      );
      return const Success(null);
    } catch (_) {
      if (current()) state = AsyncData(before);
      return const Error('操作结果待确认，请刷新规则后核对');
    }
  }
}

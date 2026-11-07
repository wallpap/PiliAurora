import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/models/remote/space_setting/privacy.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';

class SpacePrivacyState {
  SpacePrivacyState({
    required this.privacy,
    required Map<String, int?> confirmed,
    Map<String, int?>? values,
    this.saving = false,
  }) : confirmed = Map.unmodifiable(confirmed),
       values = Map.unmodifiable(values ?? confirmed);
  final Privacy privacy;
  final Map<String, int?> confirmed;
  final Map<String, int?> values;
  final bool saving;
  bool get dirty =>
      values.entries.any((entry) => confirmed[entry.key] != entry.value);
  SpacePrivacyState operation({
    Map<String, int?>? values,
    bool saving = false,
  }) => SpacePrivacyState(
    privacy: privacy,
    confirmed: confirmed,
    values: values ?? this.values,
    saving: saving,
  );
}

final spacePrivacyProvider =
    AsyncNotifierProvider<SpacePrivacyNotifier, SpacePrivacyState>(
      SpacePrivacyNotifier.new,
      isAutoDispose: true,
      retry: (_, _) => null,
    );

class SpacePrivacyNotifier extends AsyncNotifier<SpacePrivacyState> {
  @override
  Future<SpacePrivacyState> build() async {
    final account = ref.watch(mainAccountProvider);
    if (!account.isLogin) throw const Error('账号未登录');
    final result = await UserHttp.spaceSetting(account: account);
    final privacy = result.data.privacy;
    if (privacy == null) throw const Error('空间设置响应不完整');
    return SpacePrivacyState(
      privacy: privacy,
      confirmed: {
        for (final item in [
          ...privacy.list1,
          ...privacy.list2,
          ...privacy.list3,
        ])
          item.key: item.value,
      },
    );
  }

  void setValue(String key, bool value) {
    final before = state.value;
    if (state.isLoading || state.hasError || before == null || before.saving) {
      return;
    }
    final account = ref.read(mainAccountProvider);
    if (!identical(account, Accounts.main)) return;
    final items = [
      ...before.privacy.list1,
      ...before.privacy.list2,
      ...before.privacy.list3,
    ].where((item) => item.key == key);
    if (items.isEmpty) return;
    final item = items.first;
    state = AsyncData(
      before.operation(
        values: {
          ...before.values,
          key: (item.isReverse ? !value : value) ? 1 : 0,
        },
      ),
    );
  }

  Future<LoadingState<void>> save() async {
    final before = state.value;
    final owner = ref;
    final account = owner.read(mainAccountProvider);
    if (state.isLoading ||
        state.hasError ||
        before == null ||
        before.saving ||
        !identical(account, Accounts.main)) {
      return const Error('账号或设置已更新，请重试');
    }
    if (!before.dirty) return const Success(null);
    state = AsyncData(before.operation(saving: true));
    try {
      final result = await UserHttp.spaceSettingMod(
        Map<String, dynamic>.from(before.values),
        account: account,
      );
      if (!owner.mounted || !identical(account, Accounts.main)) {
        return const Error('账号已切换或页面已关闭');
      }
      state = AsyncData(
        result.isSuccess
            ? SpacePrivacyState(
                privacy: before.privacy,
                confirmed: before.values,
              )
            : before,
      );
      return result;
    } catch (_) {
      if (owner.mounted && identical(account, Accounts.main)) {
        state = AsyncData(before);
      }
      return const Error('保存结果待确认，请重试或重新查询');
    }
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/live.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/live/live_area_list/area_item.dart';
import 'package:pili_aurora/models/remote/live/live_area_list/area_list.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';

final liveAreasProvider = FutureProvider.autoDispose<List<AreaList>>((
  ref,
) async {
  final account = ref.watch(recommendAccountProvider);
  return List.unmodifiable(
    (await LiveHttp.liveAreaList(account: account)).data ?? [],
  );
}, retry: (_, _) => null);

class LiveAreaPreferences {
  LiveAreaPreferences(
    Iterable<AreaItem> items, {
    this.saving = false,
    Object? source,
  }) : items = List.unmodifiable(items),
       source = source ?? Object();
  final List<AreaItem> items;
  final bool saving;
  final Object source;
}

final liveAreaPreferencesProvider =
    AsyncNotifierProvider.autoDispose<
      LiveAreaPreferencesNotifier,
      LiveAreaPreferences
    >(
      LiveAreaPreferencesNotifier.new,
      retry: (_, _) => null,
    );

class LiveAreaPreferencesNotifier extends AsyncNotifier<LiveAreaPreferences> {
  @override
  Future<LiveAreaPreferences> build() async {
    final account = ref.watch(mainAccountProvider);
    if (!account.isLogin) throw const Error('账号未登录');
    return LiveAreaPreferences(
      (await LiveHttp.getLiveFavTag(account: account)).data,
    );
  }

  Future<LoadingState<void>> save(Object source, List<AreaItem> draft) async {
    final before = state.value;
    final owner = ref;
    final account = owner.read(mainAccountProvider);
    if (state.isLoading ||
        state.hasError ||
        before == null ||
        before.saving ||
        !identical(source, before.source) ||
        !identical(account, Accounts.main)) {
      return const Error('标签或账号已更新，请重新编辑');
    }
    final items = draft.toSet().toList(growable: false);
    state = AsyncData(
      LiveAreaPreferences(before.items, source: before.source, saving: true),
    );
    try {
      final result = await LiveHttp.setLiveFavTag(
        ids: items.map((e) => e.id).join(','),
        account: account,
      );
      if (!owner.mounted || !identical(account, Accounts.main)) {
        return const Error('账号已切换或页面已关闭');
      }
      state = AsyncData(result.isSuccess ? LiveAreaPreferences(items) : before);
      return result;
    } catch (error, stackTrace) {
      if (owner.mounted && identical(account, Accounts.main)) {
        state = AsyncData(before);
      }
      return UnknownResult(cause: error, stackTrace: stackTrace);
    }
  }
}

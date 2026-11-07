import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/follow.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/models/common/follow_order_type.dart';
import 'package:pili_aurora/models/remote/follow/data.dart';
import 'package:pili_aurora/models/remote/follow/list.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/bili_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

final followOrderProvider =
    NotifierProvider<FollowOrderNotifier, FollowOrderType>(
      FollowOrderNotifier.new,
    );

class FollowOrderNotifier extends Notifier<FollowOrderType> {
  @override
  FollowOrderType build() => Pref.followOrderType;
  void toggle() {
    state = state == FollowOrderType.def
        ? FollowOrderType.attention
        : FollowOrderType.def;
    GStorage.setting.put(SettingBoxKey.followOrderType, state.index);
  }
}

typedef FollowingQuery = ({int? mid, int? tagid, String? keyword});
final followingProvider =
    AsyncNotifierProvider.family<
      FollowingNotifier,
      FollowingState,
      FollowingQuery
    >(FollowingNotifier.new, isAutoDispose: true, retry: (_, _) => null);

class FollowingState {
  FollowingState({
    required this.source,
    required Iterable<FollowItemModel> items,
    required this.total,
    required this.nextPage,
    required this.hasMore,
    this.isLoadingMore = false,
    this.pageError,
  }) : items = List.unmodifiable(items);
  final Object source;
  final List<FollowItemModel> items;
  final int? total;
  final int nextPage;
  final bool hasMore;
  final bool isLoadingMore;
  final String? pageError;
  bool get canLoadMore => hasMore && !isLoadingMore && pageError == null;
  FollowingState operation({bool isLoadingMore = false, String? pageError}) =>
      FollowingState(
        source: source,
        items: items,
        total: total,
        nextPage: nextPage,
        hasMore: hasMore,
        isLoadingMore: isLoadingMore,
        pageError: pageError,
      );
}

class FollowingNotifier extends AsyncNotifier<FollowingState> {
  FollowingNotifier(this.query);
  final FollowingQuery query;
  static const pageSize = 20;
  @override
  Future<FollowingState> build() async {
    final account = ref.watch(mainAccountProvider);
    final order = query.keyword == null
        ? ref.watch(followOrderProvider)
        : FollowOrderType.attention;
    return _merge(null, await _page(account, order, 1), 1);
  }

  Future<FollowData> _page(
    Account account,
    FollowOrderType order,
    int page,
  ) async {
    final mid = query.mid ?? account.mid;
    final result = query.keyword != null
        ? await MemberHttp.followSearch(
            account: account,
            mid: mid,
            ps: pageSize,
            pn: page,
            name: query.keyword!,
          )
        : query.tagid != null
        ? await MemberHttp.followUpGroup(
            account: account,
            mid: mid,
            tagid: query.tagid!,
            pn: page,
            orderType: order.type,
          )
        : await FollowHttp.followings(
            account: account,
            vmid: mid,
            pn: page,
            orderType: order.type,
          );
    return switch (result) {
      Success(:final response) => response,
      _ => throw result,
    };
  }

  FollowingState _merge(
    FollowingState? current,
    FollowData response,
    int page,
  ) {
    final rows = response.list ?? const <FollowItemModel>[];
    final ids = <int>{};
    final items = [
      for (final row in [...?current?.items, ...rows])
        if (ids.add(row.mid)) row,
    ];
    final total = response.total ?? current?.total;
    return FollowingState(
      source: current?.source ?? Object(),
      items: items,
      total: total,
      nextPage: page + 1,
      hasMore:
          rows.isNotEmpty &&
          (total == null ? rows.length >= pageSize : page * pageSize < total) &&
          (current == null || items.length > current.items.length),
    );
  }

  Future<void> loadMore({bool retry = false}) async {
    final current = state.value;
    if (state.isLoading ||
        state.hasError ||
        current == null ||
        !current.hasMore ||
        current.isLoadingMore ||
        (!retry && current.pageError != null)) {
      return;
    }
    final owner = ref;
    final account = owner.read(mainAccountProvider);
    if (!identical(account, Accounts.main)) return;
    final order = query.keyword == null
        ? owner.read(followOrderProvider)
        : FollowOrderType.attention;
    state = AsyncData(current.operation(isLoadingMore: true));
    try {
      final response = await _page(account, order, current.nextPage);
      if (!owner.mounted || !identical(account, Accounts.main)) return;
      state = AsyncData(_merge(current, response, current.nextPage));
    } catch (_) {
      if (owner.mounted && identical(account, Accounts.main)) {
        state = AsyncData(current.operation(pageError: '加载失败，点击重试'));
      }
    }
  }
}

class FollowTag {
  const FollowTag({required this.id, required this.name, this.count, this.tip});
  final int id;
  final String name;
  final int? count;
  final String? tip;
  bool get isCustom => BiliUtils.isCustomFollowTag(id);
}

class FollowTagsState {
  FollowTagsState(
    Iterable<FollowTag> tags, {
    Object? source,
    this.isSaving = false,
  }) : tags = List.unmodifiable(tags),
       source = source ?? Object();
  final List<FollowTag> tags;
  final Object source;
  final bool isSaving;
}

final followTagsProvider =
    AsyncNotifierProvider<FollowTagsNotifier, FollowTagsState>(
      FollowTagsNotifier.new,
      isAutoDispose: true,
      retry: (_, _) => null,
    );

class FollowTagsNotifier extends AsyncNotifier<FollowTagsState> {
  @override
  Future<FollowTagsState> build() async {
    final account = ref.watch(mainAccountProvider);
    if (!account.isLogin) throw const Error('账号未登录');
    final result = await MemberHttp.followUpTags(account: account);
    final ids = <int>{};
    return FollowTagsState([
      for (final tag in result.data)
        if (tag.tagid != null && ids.add(tag.tagid!))
          FollowTag(
            id: tag.tagid!,
            name: tag.name ?? '',
            count: tag.count,
            tip: tag.tip,
          ),
    ]);
  }

  Future<LoadingState<T>> _write<T>(
    Object source,
    Future<LoadingState<T>> Function(Account) send,
    List<FollowTag> Function(List<FollowTag>, T) apply, {
    bool reloadLists = false,
  }) async {
    final before = state.value;
    final owner = ref;
    final account = owner.read(mainAccountProvider);
    if (state.isLoading ||
        state.hasError ||
        before == null ||
        before.isSaving ||
        !identical(source, before.source) ||
        !account.isLogin ||
        !identical(account, Accounts.main)) {
      return const Error('分组或账号已更新，请重试');
    }
    state = AsyncData(
      FollowTagsState(before.tags, source: before.source, isSaving: true),
    );
    try {
      final result = await send(account);
      if (!owner.mounted || !identical(account, Accounts.main)) {
        return const Error('账号已切换或页面已关闭');
      }
      if (result case Success(:final response)) {
        state = AsyncData(FollowTagsState(apply(before.tags, response)));
        if (reloadLists) owner.invalidate(followingProvider);
      } else {
        state = AsyncData(before);
      }
      return result;
    } catch (_) {
      if (owner.mounted && identical(account, Accounts.main)) {
        state = AsyncData(before);
      }
      return const Error('操作未完成，请刷新分组后核对');
    }
  }

  Future<LoadingState<int>> create(String name, Object source) {
    name = name.trim();
    if (name.isEmpty || name.runes.length > 16) {
      return Future.value(const Error('分组名称须为 1–16 个字符'));
    }
    return _write(
      source,
      (account) => MemberHttp.createFollowTag(name, account: account),
      (tags, id) => [...tags, FollowTag(id: id, name: name, count: 0)],
    );
  }

  Future<LoadingState<void>> rename(int id, String name, Object source) {
    name = name.trim();
    if (!BiliUtils.isCustomFollowTag(id) ||
        name.isEmpty ||
        name.runes.length > 16 ||
        !(state.value?.tags.any((tag) => tag.id == id) ?? false)) {
      return Future.value(const Error('分组已更新或名称无效'));
    }
    return _write(
      source,
      (account) => MemberHttp.updateFollowTag(id, name, account: account),
      (tags, _) => [
        for (final tag in tags)
          if (tag.id == id)
            FollowTag(id: id, name: name, count: tag.count, tip: tag.tip)
          else
            tag,
      ],
    );
  }

  Future<LoadingState<void>> remove(int id, Object source) {
    if (!BiliUtils.isCustomFollowTag(id) ||
        !(state.value?.tags.any((tag) => tag.id == id) ?? false)) {
      return Future.value(const Error('分组已更新'));
    }
    return _write(
      source,
      (account) => MemberHttp.delFollowTag(id, account: account),
      (tags, _) => tags.where((tag) => tag.id != id).toList(),
      reloadLists: true,
    );
  }

  Future<LoadingState<void>> reorder(List<int> ids, Object source) {
    final custom =
        state.value?.tags.where((tag) => tag.isCustom).toList() ?? [];
    if (ids.isEmpty ||
        ids.length != custom.length ||
        ids.toSet().length != ids.length ||
        !custom.every((tag) => ids.contains(tag.id))) {
      return Future.value(const Error('分组已更新，请重新排序'));
    }
    final order = List<int>.of(ids);
    return _write(
      source,
      (account) =>
          FollowHttp.sortFollowTag(account: account, tagids: order.join(',')),
      (tags, _) => [
        ...tags.where((tag) => !tag.isCustom),
        for (final id in order) custom.firstWhere((tag) => tag.id == id),
      ],
    );
  }

  Future<LoadingState<void>> assign(
    int mid,
    Set<int> ids,
    Object source,
  ) async {
    final selected = Set<int>.of(ids);
    if (!(state.value?.tags
            .map((tag) => tag.id)
            .toSet()
            .containsAll(selected) ??
        false)) {
      return const Error('分组已更新，请重试');
    }
    final owner = ref;
    final result = await _write(
      source,
      (account) => MemberHttp.addUsers(
        '$mid',
        selected.isEmpty ? '0' : selected.join(','),
        account: account,
      ),
      (tags, _) => tags,
      reloadLists: true,
    );
    // 成员变动后的计数由服务端重新确认，不推算未知的旧分组归属。
    if (result.isSuccess && owner.mounted) owner.invalidateSelf();
    return result;
  }
}

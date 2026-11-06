import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/msg/msg_unread_type.dart';
import 'package:pili_aurora/models/remote/msg/msg_like/item.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

@immutable
class FeedCursor {
  const FeedCursor({this.id, this.time, this.page, this.lastMid});

  final int? id;
  final int? time;
  final int? page;
  final int? lastMid;
}

@immutable
class FeedPage<T> {
  FeedPage({
    required Iterable<T> items,
    this.cursor,
    this.isEnd = false,
    this.notifyUnread = true,
    this.metadata,
  }) : items = List<T>.unmodifiable(items);

  final List<T> items;
  final FeedCursor? cursor;
  final bool isEnd;
  final bool notifyUnread;
  final Object? metadata;
}

@immutable
class FeedSnapshot<T> {
  const FeedSnapshot({
    required this.loadingState,
    this.isEnd = false,
    this.isLoadingMore = false,
    this.paginationError,
    this.metadata,
  });

  final LoadingState<List<T>?> loadingState;
  final bool isEnd;
  final bool isLoadingMore;
  final LoadingState<FeedPage<T>>? paginationError;
  final Object? metadata;
}

typedef FeedRequest<T> = Future<LoadingState<FeedPage<T>>> Function(
  Account account,
  FeedCursor? cursor,
);
typedef FeedDelete = Future<LoadingState<void>> Function(
  Account account,
  Object id,
);

typedef FeedAcknowledge<T> = Future<LoadingState<void>> Function(
  Account account,
  FeedPage<T> page,
);

/// 分页查询的业务状态。协议 DTO 在请求适配器中复制后才进入此句柄。
class FeedHandle<T> {
  FeedHandle({
    required this.session,
    required this.request,
    required this.idOf,
    this.delete,
    this.acknowledge,
    this.notifyUnreadOnRefresh = false,
    this.readType,
    this.maxItems,
  }) : state = ValueNotifier(
         FeedSnapshot(loadingState: LoadingState.loading()),
       );

  final MessagingSession session;
  final FeedRequest<T> request;
  final Object? Function(T item) idOf;
  final FeedDelete? delete;
  final FeedAcknowledge<T>? acknowledge;
  final bool notifyUnreadOnRefresh;
  final MsgUnReadType? readType;
  final int? maxItems;
  final ValueNotifier<FeedSnapshot<T>> state;

  int _generation = 0;
  bool _disposed = false;
  bool _isLoadingMore = false;
  FeedCursor? _cursor;
  Future<void>? _refreshFuture;

  bool get canLoadMore =>
      !_disposed &&
      session.isActive &&
      !_isLoadingMore &&
      !state.value.isEnd &&
      state.value.loadingState.dataOrNull != null;

  Future<void> refresh() {
    if (_disposed || !session.isActive) return Future<void>.value();
    final current = _refreshFuture;
    if (current != null) return current;

    return _refreshFuture = _refresh().whenComplete(() {
      _refreshFuture = null;
    });
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    _cursor = null;
    _isLoadingMore = false;
    state.value = FeedSnapshot(loadingState: LoadingState.loading());
    final response = await session.run((account) => request(account, null));
    if (!_isCurrent(generation)) return;

    switch (response) {
      case Success<FeedPage<T>>(:final response):
        _cursor = response.cursor;
        state.value = FeedSnapshot(
          loadingState: Success<List<T>?>(_merge(<T>[], response.items)),
          isEnd:
              response.isEnd ||
              response.items.isEmpty ||
              (maxItems != null && response.items.length >= maxItems!),
          metadata: response.metadata,
        );
        if (notifyUnreadOnRefresh && response.notifyUnread) {
          if (acknowledge == null) {
            session.notifyChanged(
              MessagingChangeKind.unread,
              readType: readType,
            );
          } else {
            unawaited(_acknowledge(response));
          }
        }
      case Error():
        state.value = FeedSnapshot(loadingState: response);
      case Loading():
        state.value = FeedSnapshot(loadingState: LoadingState.loading());
    }
  }

  Future<void> _acknowledge(FeedPage<T> page) async {
    final result = await session.run(
      (account) => acknowledge!(account, page),
    );
    // ACK 失败保留列表与未读数，手动刷新时再次确认。
    // 已发出的 ACK 属于账号；退出页面后仍需同步共享角标。
    if (session.isActive && result.isSuccess) {
      session.notifyChanged(MessagingChangeKind.unread, readType: readType);
    }
  }

  Future<void> loadMore() async {
    if (!canLoadMore) return;
    final generation = _generation;
    _isLoadingMore = true;
    state.value = FeedSnapshot(
      loadingState: state.value.loadingState,
      isEnd: state.value.isEnd,
      isLoadingMore: true,
      metadata: state.value.metadata,
    );
    try {
      final response = await session.run(
        (account) => request(account, _cursor),
      );
      if (!_isCurrent(generation)) return;
      switch (response) {
        case Success<FeedPage<T>>(:final response):
          final existing = state.value.loadingState.dataOrNull ?? <T>[];
          _cursor = response.cursor;
          final merged = _merge(existing, response.items);
          state.value = FeedSnapshot(
            loadingState: Success<List<T>?>(merged),
            isEnd:
                response.isEnd ||
                response.items.isEmpty ||
                (maxItems != null && merged.length >= maxItems!),
            metadata: response.metadata ?? state.value.metadata,
          );
        case Error():
          state.value = FeedSnapshot(
            loadingState: state.value.loadingState,
            isEnd: state.value.isEnd,
            paginationError: response,
            metadata: state.value.metadata,
          );
        case Loading():
          state.value = FeedSnapshot(
            loadingState: state.value.loadingState,
            isEnd: state.value.isEnd,
            metadata: state.value.metadata,
          );
      }
    } finally {
      if (_isCurrent(generation)) {
        _isLoadingMore = false;
        if (state.value.isLoadingMore) {
          state.value = FeedSnapshot(
            loadingState: state.value.loadingState,
            isEnd: state.value.isEnd,
            paginationError: state.value.paginationError,
            metadata: state.value.metadata,
          );
        }
      }
    }
  }

  Future<LoadingState<void>> remove(Object id) async {
    final deleteRequest = delete;
    if (_disposed || !session.isActive || deleteRequest == null) {
      return const Error('当前操作不可用');
    }
    final result = await session.run(
      (account) => deleteRequest(account, id),
    );
    if (_disposed || !session.isActive) return const Error('账号已切换');
    if (result case Success<void>()) {
      _generation++;
      _isLoadingMore = false;
      final items = state.value.loadingState.dataOrNull;
      if (items != null) {
        state.value = FeedSnapshot(
          loadingState: Success<List<T>?>(
            List<T>.unmodifiable(items.where((item) => idOf(item) != id)),
          ),
          isEnd: state.value.isEnd,
          metadata: state.value.metadata,
        );
      }
      session.notifyChanged(MessagingChangeKind.unread);
    }
    return result;
  }

  List<T> _merge(Iterable<T> first, Iterable<T> second) {
    final result = <T>[];
    final seen = <Object>{};
    for (final item in [...first, ...second]) {
      final id = idOf(item);
      if (id == null || seen.add(id)) result.add(item);
    }
    return List<T>.unmodifiable(result);
  }

  bool _isCurrent(int generation) =>
      !_disposed && session.isActive && generation == _generation;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    state.dispose();
  }
}

@immutable
class LikeFeedSnapshot {
  const LikeFeedSnapshot({
    required this.loadingState,
    this.isEnd = false,
    this.isLoadingMore = false,
    this.paginationError,
  });

  final LoadingState<PairLikeItems> loadingState;
  final bool isEnd;
  final bool isLoadingMore;
  final LoadingState<FeedPage<MsgLikeItem>>? paginationError;
}

@immutable
class PairLikeItems {
  PairLikeItems({
    required Iterable<MsgLikeItem> latest,
    required Iterable<MsgLikeItem> total,
  }) : latest = List<MsgLikeItem>.unmodifiable(latest),
       total = List<MsgLikeItem>.unmodifiable(total);

  final List<MsgLikeItem> latest;
  final List<MsgLikeItem> total;
}

typedef LikeFeedRequest = Future<LoadingState<LikeFeedPage>> Function(
  Account account,
  FeedCursor? cursor,
);
typedef LikeFeedDelete = Future<LoadingState<void>> Function(
  Account account,
  Object id,
);
typedef LikeNoticeRequest = Future<LoadingState<void>> Function(
  Account account,
  Object id,
  int noticeState,
);

@immutable
class LikeFeedPage {
  LikeFeedPage({
    required Iterable<MsgLikeItem> latest,
    required Iterable<MsgLikeItem> total,
    this.cursor,
    this.isEnd = false,
  }) : latest = List<MsgLikeItem>.unmodifiable(latest),
       total = List<MsgLikeItem>.unmodifiable(total);

  final List<MsgLikeItem> latest;
  final List<MsgLikeItem> total;
  final FeedCursor? cursor;
  final bool isEnd;
}

/// 点赞接口的 latest 与 total 分组始终独立；分页只追加 total，刷新重置分页终态。
class LikeFeedHandle {
  LikeFeedHandle({
    required this.session,
    required this.request,
    required this.delete,
    required this.setNoticeRequest,
  }) : state = ValueNotifier(
         LikeFeedSnapshot(loadingState: LoadingState.loading()),
       );

  final MessagingSession session;
  final LikeFeedRequest request;
  final LikeFeedDelete delete;
  final LikeNoticeRequest setNoticeRequest;
  final ValueNotifier<LikeFeedSnapshot> state;
  int _generation = 0;
  bool _disposed = false;
  bool _isLoadingMore = false;
  FeedCursor? _cursor;
  Future<void>? _refreshFuture;
  final Map<Object, int> _noticeVersions = {};

  bool get canLoadMore =>
      !_disposed &&
      session.isActive &&
      !_isLoadingMore &&
      !state.value.isEnd &&
      state.value.loadingState.dataOrNull != null;

  Future<void> refresh() {
    if (_disposed || !session.isActive) return Future<void>.value();
    final current = _refreshFuture;
    if (current != null) return current;
    return _refreshFuture = _refresh().whenComplete(() {
      _refreshFuture = null;
    });
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    _cursor = null;
    _isLoadingMore = false;
    state.value = LikeFeedSnapshot(loadingState: LoadingState.loading());
    final response = await session.run((account) => request(account, null));
    if (!_isCurrent(generation)) return;
    switch (response) {
      case Success<LikeFeedPage>(:final response):
        _cursor = response.cursor;
        state.value = LikeFeedSnapshot(
          loadingState: Success(
            PairLikeItems(latest: response.latest, total: response.total),
          ),
          isEnd: response.isEnd || response.total.isEmpty,
        );
        session.notifyChanged(
          MessagingChangeKind.unread,
          readType: MsgUnReadType.like,
        );
      case Error():
        state.value = LikeFeedSnapshot(loadingState: response);
      case Loading():
        state.value = LikeFeedSnapshot(
          loadingState: LoadingState.loading(),
        );
    }
  }

  Future<void> loadMore() async {
    if (!canLoadMore) return;
    final generation = _generation;
    _isLoadingMore = true;
    state.value = LikeFeedSnapshot(
      loadingState: state.value.loadingState,
      isEnd: state.value.isEnd,
      isLoadingMore: true,
    );
    try {
      final response = await session.run(
        (account) => request(account, _cursor),
      );
      if (!_isCurrent(generation)) return;
      switch (response) {
        case Success<LikeFeedPage>(:final response):
          final previous = state.value.loadingState.data;
          _cursor = response.cursor;
          state.value = LikeFeedSnapshot(
            loadingState: Success(
              PairLikeItems(
                latest: previous.latest,
                total: _merge(previous.total, response.total),
              ),
            ),
            isEnd: response.isEnd || response.total.isEmpty,
          );
        case Error():
          state.value = LikeFeedSnapshot(
            loadingState: state.value.loadingState,
            isEnd: state.value.isEnd,
            paginationError: response,
          );
        case Loading():
          state.value = LikeFeedSnapshot(
            loadingState: state.value.loadingState,
            isEnd: state.value.isEnd,
          );
      }
    } finally {
      if (_isCurrent(generation)) {
        _isLoadingMore = false;
        if (state.value.isLoadingMore) {
          state.value = LikeFeedSnapshot(
            loadingState: state.value.loadingState,
            isEnd: state.value.isEnd,
            paginationError: state.value.paginationError,
          );
        }
      }
    }
  }

  Future<LoadingState<void>> remove(Object id, {required bool latest}) async {
    if (_disposed || !session.isActive) return const Error('当前操作不可用');
    final result = await session.run((account) => delete(account, id));
    if (_disposed || !session.isActive) return const Error('账号已切换');
    if (result case Success<void>()) {
      _generation++;
      _isLoadingMore = false;
      final current = state.value.loadingState.dataOrNull;
      if (current != null) {
        List<MsgLikeItem> without(List<MsgLikeItem> source) =>
            List.unmodifiable(source.where((item) => item.id != id));
        state.value = LikeFeedSnapshot(
          loadingState: Success(
            PairLikeItems(
              latest: latest ? without(current.latest) : current.latest,
              total: latest ? current.total : without(current.total),
            ),
          ),
          isEnd: state.value.isEnd,
        );
      }
      session.notifyChanged(MessagingChangeKind.unread);
    }
    return result;
  }

  Future<LoadingState<void>> setNotice(Object id, bool isNotice) async {
    if (_disposed || !session.isActive) return const Error('当前操作不可用');
    final version = (_noticeVersions[id] ?? 0) + 1;
    _noticeVersions[id] = version;
    final noticeState = isNotice ? 1 : 0;
    final result = await session.run(
      (account) => setNoticeRequest(account, id, noticeState),
    );
    if (_disposed || !session.isActive) return const Error('账号已切换');
    if (result case Success<void>()) {
      if (_noticeVersions[id] != version) return result;
      _generation++;
      _isLoadingMore = false;
      final current = state.value.loadingState.dataOrNull;
      if (current != null) {
        MsgLikeItem update(MsgLikeItem item) => item.id == id
            ? MsgLikeItem(
                id: item.id,
                users: item.users,
                item: item.item,
                counts: item.counts,
                likeTime: item.likeTime,
                noticeState: noticeState,
              )
            : item;
        state.value = LikeFeedSnapshot(
          loadingState: Success(
            PairLikeItems(
              latest: current.latest.map(update),
              total: current.total.map(update),
            ),
          ),
          isEnd: state.value.isEnd,
        );
      }
      session.notifyChanged(MessagingChangeKind.settings);
    }
    return result;
  }

  List<MsgLikeItem> _merge(
    Iterable<MsgLikeItem> first,
    Iterable<MsgLikeItem> second,
  ) {
    final result = <MsgLikeItem>[];
    final seen = <Object>{};
    for (final item in [...first, ...second]) {
      final id = item.id;
      if (id == null || seen.add(id)) result.add(item);
    }
    return List<MsgLikeItem>.unmodifiable(result);
  }

  bool _isCurrent(int generation) =>
      !_disposed && session.isActive && generation == _generation;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    state.dispose();
  }
}

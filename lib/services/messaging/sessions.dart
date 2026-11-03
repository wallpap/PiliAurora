import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/services/messaging/session_adapter.dart';
import 'package:pili_aurora/services/messaging/session_models.dart';

const _sessionsResourceKey = 'messaging.sessions';

Sessions sessionsFor(MessagingSession scope) => scope.resource(
  _sessionsResourceKey,
  () => Sessions(scope),
  (sessions) => sessions.dispose(),
);

class Sessions {
  Sessions(this.scope, {this.adapter = const SessionAdapter()}) {
    _changeSubscription = scope.changes.listen(_onScopeChange);
  }

  final MessagingSession scope;
  final SessionAdapter adapter;
  final Map<SessionKey, SessionEntry> _entries = {};
  final Map<SessionFolder, SessionListHandle> _lists = {};
  final Map<(SessionKey, String), int> _operationVersions = {};
  final Map<SessionKey, int> _entryRevisions = {};
  late final StreamSubscription<MessagingChange> _changeSubscription;
  bool _disposed = false;
  bool _emittingLocalChange = false;

  SessionEntry? entry(SessionKey key) => _entries[key];

  SessionListHandle list(SessionFolder folder) => _lists.putIfAbsent(
    folder,
    () => SessionListHandle._(this, folder),
  );

  Future<LoadingState<void>> remove(SessionKey key) async {
    final target = _entries[key]?.target;
    if (target is! PrivateSessionTarget) {
      return const Error('该会话不支持删除');
    }
    final version = _beginOperation(key, 'remove');
    final result = await scope.run<void>(
      (account) => adapter.remove(account: account, talkerId: target.talkerId),
    );
    if (!scope.isActive || !result.isSuccess) return result;
    if (_isCurrentOperation(key, 'remove', version)) {
      _invalidateListsFor(key);
      _entries.remove(key);
      _entryRevisions.remove(key);
      for (final handle in _lists.values) {
        handle._remove(key);
      }
    }
    _notifyChanged(key, unread: true);
    return result;
  }

  Future<LoadingState<void>> setPinned(
    SessionKey key, {
    required bool isPinned,
  }) async {
    final current = _entries[key];
    if (current == null) return const Error('会话已从列表移除');
    final version = _beginOperation(key, 'pinned');
    final result = await scope.run<void>(
      (account) => adapter.setPinned(
        account: account,
        key: key,
        isPinned: isPinned,
      ),
    );
    if (!scope.isActive || !result.isSuccess) return result;
    if (_isCurrentOperation(key, 'pinned', version)) {
      final latest = _entries[key];
      if (latest != null) {
        _invalidateListsFor(key);
        _replaceEntry(latest.copyWith(isPinned: !isPinned));
      }
    }
    _notifyChanged(key);
    return result;
  }

  Future<LoadingState<void>> setMuted(
    SessionKey key, {
    required bool isMuted,
  }) async {
    final current = _entries[key];
    final target = current?.target;
    if (current == null || target is! PrivateSessionTarget) {
      return const Error('该会话不支持免打扰');
    }
    final version = _beginOperation(key, 'muted');
    final result = await scope.run<void>(
      (account) => adapter.setMuted(
        account: account,
        talkerId: target.talkerId,
        isMuted: isMuted,
      ),
    );
    if (!scope.isActive || !result.isSuccess) return result;
    if (_isCurrentOperation(key, 'muted', version)) {
      final latest = _entries[key];
      if (latest != null) {
        _invalidateListsFor(key);
        _replaceEntry(latest.copyWith(isMuted: !isMuted));
      }
    }
    _notifyChanged(key);
    return result;
  }

  Future<LoadingState<void>> markRead(SessionKey key) async {
    final current = _entries[key];
    final target = current?.target;
    if (current == null || target is! PrivateSessionTarget) {
      return const Error('该会话不支持标记已读');
    }
    final version = _beginOperation(key, 'read');
    final result = await scope.run<void>(
      (account) => adapter.markRead(
        account: account,
        talkerId: target.talkerId,
      ),
    );
    if (!scope.isActive || !result.isSuccess) return result;
    if (_isCurrentOperation(key, 'read', version)) {
      final latest = _entries[key];
      if (latest != null) {
        _invalidateListsFor(key);
        _replaceEntry(latest.clearUnread());
      }
    }
    _notifyChanged(key, unread: true);
    return result;
  }

  Future<LoadingState<void>> clearUnread(SessionFolder folder) async {
    final result = await scope.run<void>(
      (account) => adapter.clearUnread(account: account, folder: folder),
    );
    if (!scope.isActive || !result.isSuccess) return result;
    final ids = _lists[folder]?._ids.toSet() ?? const <SessionKey>{};
    for (final handle in _lists.values) {
      if (handle.folder != folder && !handle._ids.any(ids.contains)) continue;
      handle._markStale();
      if (handle._started) unawaited(handle.refresh());
    }
    _notifyChanged(null, unread: true);
    return result;
  }

  Future<LoadingState<void>> deleteList(SessionFolder folder) async {
    final result = await scope.run<void>(
      (account) => adapter.deleteList(account: account, folder: folder),
    );
    if (!scope.isActive || !result.isSuccess) return result;
    final handle = _lists[folder];
    if (handle != null) {
      final removedIds = handle._ids.toSet();
      handle
        .._invalidateRequest(publish: false)
        .._replaceIds(const [], hasMore: false, cursor: null)
        .._publish();
      _dropOrphans(removedIds);
    }
    _notifyChanged(null, unread: true);
    return result;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final handle in _lists.values) {
      handle.dispose();
    }
    _lists.clear();
    _entries.clear();
    _operationVersions.clear();
    _entryRevisions.clear();
    unawaited(_changeSubscription.cancel());
  }

  Future<LoadingState<SessionPageResult>> _loadPage({
    required SessionFolder folder,
    SessionPageCursor? cursor,
  }) => scope.run<SessionPageResult>(
    (account) => adapter.loadPage(
      account: account,
      folder: folder,
      cursor: cursor,
    ),
  );

  Map<SessionKey, int> _captureEntryRevisions() => Map.of(_entryRevisions);

  void _mergePage(
    SessionListHandle handle,
    SessionPageResult result, {
    required bool replace,
    required Map<SessionKey, int> revisions,
  }) {
    for (final incoming in result.entries) {
      final existing = _entries[incoming.key];
      final changedWhileLoading =
          existing != null &&
          (_entryRevisions[incoming.key] ?? 0) !=
              (revisions[incoming.key] ?? 0);
      if (!changedWhileLoading) {
        _entries[incoming.key] = incoming;
      }
    }
    final ids = replace ? <SessionKey>[] : List.of(handle._ids);
    final seen = ids.toSet();
    for (final incoming in result.entries) {
      if (seen.add(incoming.key)) ids.add(incoming.key);
    }
    final removedIds = replace
        ? handle._ids.where((id) => !ids.contains(id)).toSet()
        : const <SessionKey>{};
    handle._replaceIds(
      ids,
      hasMore: result.hasMore && result.cursor != null,
      cursor: result.cursor,
      menuItems: result.menuItems,
      outsideItems: result.outsideItems,
    );
    _dropOrphans(removedIds);
    _publishAll();
  }

  void _replaceEntry(SessionEntry value) {
    _entries[value.key] = value;
    _entryRevisions.update(
      value.key,
      (revision) => revision + 1,
      ifAbsent: () => 1,
    );
    for (final handle in _lists.values) {
      if (handle._ids.contains(value.key)) {
        handle._sortPinnedFirst();
      }
    }
    _publishAll();
  }

  void _dropOrphans(Set<SessionKey> candidates) {
    for (final key in candidates) {
      if (_lists.values.every((handle) => !handle._ids.contains(key))) {
        _entries.remove(key);
        _entryRevisions.remove(key);
      }
    }
  }

  int _beginOperation(SessionKey key, String operation) {
    final mapKey = (key, operation);
    final version = (_operationVersions[mapKey] ?? 0) + 1;
    _operationVersions[mapKey] = version;
    return version;
  }

  bool _isCurrentOperation(SessionKey key, String operation, int version) =>
      _operationVersions[(key, operation)] == version;

  void _invalidateListsFor(SessionKey key) {
    for (final handle in _lists.values) {
      if (handle._ids.contains(key)) {
        handle._invalidateRequest(publish: false);
      }
    }
  }

  void _notifyChanged(SessionKey? key, {bool unread = false}) {
    _emittingLocalChange = true;
    try {
      scope.notifyChanged(
        MessagingChangeKind.sessions,
        talkerId: _talkerId(key),
      );
      if (unread) {
        scope.notifyChanged(
          MessagingChangeKind.unread,
          talkerId: _talkerId(key),
        );
      }
    } finally {
      _emittingLocalChange = false;
    }
  }

  void _onScopeChange(MessagingChange change) {
    if (_disposed ||
        _emittingLocalChange ||
        change.kind == MessagingChangeKind.settings ||
        (change.kind == MessagingChangeKind.unread &&
            change.talkerId == null)) {
      return;
    }
    final changedKey = change.talkerId == null
        ? null
        : SessionKey(kind: SessionKeyKind.private, primary: change.talkerId!);
    if (change.kind == MessagingChangeKind.conversationRead) {
      final entry = _entries[changedKey];
      if (entry != null) {
        // ACK 已确认成功；本地立即同步，避免重查到尚未收敛的远端旧值。
        _invalidateListsFor(entry.key);
        _replaceEntry(entry.clearUnread());
      }
      return;
    }
    for (final handle in _lists.values) {
      if (!handle._started ||
          (changedKey != null &&
              handle.folder != SessionFolder.home &&
              !handle._ids.contains(changedKey))) {
        continue;
      }
      handle._markStale();
      unawaited(handle.refresh());
    }
  }

  static int? _talkerId(SessionKey? key) =>
      key?.kind == SessionKeyKind.private ? key!.primary : null;

  void _publishAll() {
    for (final handle in _lists.values) {
      handle._publish();
    }
  }
}

class SessionListHandle {
  SessionListHandle._(this._owner, this.folder) {
    _state = ValueNotifier(_snapshot());
  }

  final Sessions _owner;
  final SessionFolder folder;
  late final ValueNotifier<SessionListSnapshot> _state;
  ValueListenable<SessionListSnapshot> get state => _state;
  List<SessionKey> _ids = [];
  SessionPageCursor? _cursor;
  bool _hasMore = true;
  SessionListPhase _phase = SessionListPhase.idle;
  String? _error;
  List<SessionMenuItem> _menuItems = const [];
  List<SessionMenuItem> _outsideItems = const [];
  int _generation = 0;
  Future<LoadingState<void>>? _refreshing;
  Future<LoadingState<void>>? _loadingMore;
  bool _started = false;
  bool _disposed = false;
  bool _stale = false;

  Future<void> loadIfNeeded() async {
    if (_disposed || (_started && !_stale)) return;
    _started = true;
    _stale = false;
    await refresh();
  }

  Future<LoadingState<void>> refresh() {
    if (_disposed || !_owner.scope.isActive) {
      return Future.value(const Error('账号已切换或未登录'));
    }
    final active = _refreshing;
    if (active != null) return active;
    final generation = ++_generation;
    _loadingMore = null;
    _cursor = null;
    _hasMore = true;
    _error = null;
    _phase = _ids.isEmpty
        ? SessionListPhase.loading
        : SessionListPhase.refreshing;
    _publish();
    final task = _fetch(generation: generation, replace: true);
    _refreshing = task;
    return task.whenComplete(() {
      if (identical(_refreshing, task)) _refreshing = null;
    });
  }

  Future<LoadingState<void>> loadMore() {
    if (_disposed || !_owner.scope.isActive) {
      return Future.value(const Error('账号已切换或未登录'));
    }
    if (_refreshing case final refreshing?) return refreshing;
    if (!_hasMore || _ids.isEmpty || _phase == SessionListPhase.loading) {
      return Future.value(const Success(null));
    }
    final active = _loadingMore;
    if (active != null) return active;
    final generation = _generation;
    _phase = SessionListPhase.loadingMore;
    _error = null;
    _publish();
    final task = _fetch(generation: generation, replace: false);
    _loadingMore = task;
    return task.whenComplete(() {
      if (identical(_loadingMore, task)) _loadingMore = null;
    });
  }

  Future<LoadingState<void>> _fetch({
    required int generation,
    required bool replace,
  }) async {
    final revisions = _owner._captureEntryRevisions();
    final result = await _owner._loadPage(
      folder: folder,
      cursor: replace ? null : _cursor,
    );
    if (_disposed || !_owner.scope.isActive || generation != _generation) {
      return const Error('列表请求已过期');
    }
    switch (result) {
      case Success(:final response):
        _owner._mergePage(
          this,
          response,
          replace: replace,
          revisions: revisions,
        );
        _phase = SessionListPhase.ready;
        _error = null;
        _stale = false;
        _publish();
        return const Success(null);
      case Error(:final errMsg, :final code):
        _phase = _ids.isEmpty
            ? SessionListPhase.failed
            : SessionListPhase.ready;
        _error = errMsg;
        _stale = true;
        _publish();
        return Error(errMsg, code: code);
      case Loading():
        _phase = _ids.isEmpty ? SessionListPhase.idle : SessionListPhase.ready;
        _stale = true;
        _publish();
        return const Error('列表尚未加载');
    }
  }

  void _replaceIds(
    List<SessionKey> ids, {
    required bool hasMore,
    required SessionPageCursor? cursor,
    Iterable<SessionMenuItem>? menuItems,
    Iterable<SessionMenuItem>? outsideItems,
  }) {
    _ids = List.of(ids);
    _sortPinnedFirst();
    _hasMore = hasMore;
    _cursor = cursor;
    if (menuItems != null) _menuItems = List.unmodifiable(menuItems);
    if (outsideItems != null) _outsideItems = List.unmodifiable(outsideItems);
  }

  void _remove(SessionKey key) {
    if (_ids.remove(key)) _publish();
  }

  void _sortPinnedFirst() {
    final pinned = <SessionKey>[];
    final regular = <SessionKey>[];
    for (final key in _ids) {
      if (_owner._entries[key]?.isPinned == true) {
        pinned.add(key);
      } else {
        regular.add(key);
      }
    }
    _ids = [...pinned, ...regular];
  }

  void _invalidateRequest({bool publish = true}) {
    _generation++;
    _refreshing = null;
    _loadingMore = null;
    _phase = _ids.isEmpty ? SessionListPhase.idle : SessionListPhase.ready;
    if (publish) _publish();
  }

  void _markStale() {
    _stale = true;
    if (_refreshing != null || _loadingMore != null) {
      _invalidateRequest(publish: false);
    }
  }

  SessionListSnapshot _snapshot() => SessionListSnapshot(
    entries: _ids.map((key) => _owner._entries[key]).whereType<SessionEntry>(),
    phase: _phase,
    hasMore: _hasMore,
    generation: _generation,
    error: _error,
    menuItems: _menuItems,
    outsideItems: _outsideItems,
  );

  void _publish() {
    if (!_disposed) _state.value = _snapshot();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _state.dispose();
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fixnum/fixnum.dart';
import 'package:pili_aurora/grpc/bilibili/app/im/v1.pb.dart';
import 'package:pili_aurora/grpc/im.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/msg.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/model_avatar.dart';
import 'package:pili_aurora/models/remote/msg/im_user_infos/datum.dart';
import 'package:pili_aurora/models/remote/msg/msg_dnd/uid_setting.dart';
import 'package:pili_aurora/models/remote/msg/session_ss/data.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:protobuf/protobuf.dart'
    show GeneratedMessageGenericExtensions, PbMap;

@immutable
class WhisperSettingsSnapshot {
  const WhisperSettingsSnapshot({
    required this.loadingState,
    this.title = '',
  });

  final LoadingState<PbMap<int, Setting>> loadingState;
  final String title;
}

class _SettingWrites {
  _SettingWrites(this.confirmed);

  Setting? confirmed;
  Future<void>? tail;
  int version = 0;
}

/// 全局接收设置。设置写入前复制 protobuf，乐观回滚只覆盖本次操作。
class WhisperSettingsHandle {
  WhisperSettingsHandle({
    required this.session,
    required this.type,
  }) : state = ValueNotifier(
         WhisperSettingsSnapshot(
           loadingState: LoadingState<PbMap<int, Setting>>.loading(),
         ),
       );

  final MessagingSession session;
  final IMSettingType type;
  final ValueNotifier<WhisperSettingsSnapshot> state;
  int _generation = 0;
  final Map<int, _SettingWrites> _writes = {};
  bool _disposed = false;

  Future<void> refresh() async {
    if (_disposed || !session.isActive) return;
    if (_writes.isNotEmpty) {
      await Future.wait(_writes.values.map((writes) => writes.tail!));
      if (_isActive) await refresh();
      return;
    }
    final generation = ++_generation;
    state.value = WhisperSettingsSnapshot(
      loadingState: LoadingState<PbMap<int, Setting>>.loading(),
    );
    final result = await session.run(
      (account) => ImGrpc.getImSettings(type: type, account: account),
    );
    if (!_isCurrent(generation)) return;
    switch (result) {
      case Success<GetImSettingsReply>(:final response):
        state.value = WhisperSettingsSnapshot(
          loadingState: Success(_copySettings(response.settings)),
          title: response.pageTitle,
        );
      case Error():
        state.value = WhisperSettingsSnapshot(loadingState: result);
      case Loading():
        state.value = WhisperSettingsSnapshot(
          loadingState: LoadingState<PbMap<int, Setting>>.loading(),
        );
    }
  }

  Future<LoadingState<void>> setSetting(int key, Setting setting) async {
    final current = state.value.loadingState.dataOrNull;
    if (_disposed || !session.isActive || current == null) {
      return const Error('当前操作不可用');
    }
    final writes = _writes.putIfAbsent(
      key,
      () => _SettingWrites(current[key]?.deepCopy()),
    );
    final version = ++writes.version;
    final desired = setting.deepCopy();
    final previous = writes.tail;
    final completion = Completer<void>();
    writes.tail = completion.future;
    // 写入开始后废弃此前读取，避免覆盖本次设置。
    _generation++;
    _replaceSetting(key, desired);
    try {
      if (previous != null) await previous;
      if (!_isActive) return const Error('账号已切换');
      final result = await session.run(
        (account) async => _asVoid(
          await ImGrpc.setImSettings(
            settings: {key: desired.deepCopy()},
            account: account,
          ),
        ),
      );
      if (!_isActive) return const Error('账号已切换');
      if (result case Success<void>()) {
        writes.confirmed = desired;
        session.notifyChanged(MessagingChangeKind.settings);
      }
      if (writes.version == version) {
        _generation++;
        final confirmed = writes.confirmed;
        if (confirmed != null) {
          _replaceSetting(key, confirmed);
        } else {
          _removeSetting(key);
        }
        _writes.remove(key);
      }
      return result;
    } finally {
      completion.complete();
    }
  }

  void mergeSubSettings(int parentKey, Map<int, Setting> values) {
    final current = state.value.loadingState.dataOrNull;
    final existing = current?[parentKey];
    if (_disposed || existing == null || !existing.hasRedirect()) return;
    final updated = existing.deepCopy();
    updated.redirect.settingPage.subSettings.addEntries(
      values.entries.map(
        (entry) => MapEntry(entry.key, entry.value.deepCopy()),
      ),
    );
    _replaceSetting(parentKey, updated);
  }

  void _replaceSetting(int key, Setting setting) {
    final current = state.value.loadingState.dataOrNull;
    if (current == null || _disposed) return;
    final copy = _copySettings(current)..[key] = setting.deepCopy();
    state.value = WhisperSettingsSnapshot(
      loadingState: Success(copy),
      title: state.value.title,
    );
  }

  void _removeSetting(int key) {
    final current = state.value.loadingState.dataOrNull;
    if (current == null || _disposed) return;
    final copy = _copySettings(current)..remove(key);
    state.value = WhisperSettingsSnapshot(
      loadingState: Success(copy),
      title: state.value.title,
    );
  }

  static PbMap<int, Setting> _copySettings(Map<int, Setting> source) {
    return GetImSettingsReply(
      settings: source.entries.map(
        (entry) => MapEntry(entry.key, entry.value.deepCopy()),
      ),
    ).settings;
  }

  bool get _isActive => !_disposed && session.isActive;
  bool _isCurrent(int generation) => _isActive && generation == _generation;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _writes.clear();
    state.dispose();
  }
}

@immutable
class KeywordBlockSnapshot {
  const KeywordBlockSnapshot({
    required this.loadingState,
    this.listLimit,
    this.charLimit,
  });

  final LoadingState<List<KeywordBlockingItem>?> loadingState;
  final int? listLimit;
  final int? charLimit;
  int get count => loadingState.dataOrNull?.length ?? 0;
}

class KeywordBlockHandle {
  KeywordBlockHandle({required this.session})
    : state = ValueNotifier(
        KeywordBlockSnapshot(
          loadingState: LoadingState<List<KeywordBlockingItem>?>.loading(),
        ),
      );

  final MessagingSession session;
  final ValueNotifier<KeywordBlockSnapshot> state;
  int _generation = 0;
  bool _disposed = false;

  Future<void> refresh() async {
    if (_disposed || !session.isActive) return;
    final generation = ++_generation;
    state.value = KeywordBlockSnapshot(
      loadingState: LoadingState<List<KeywordBlockingItem>?>.loading(),
    );
    final result = await session.run(
      (account) => ImGrpc.keywordBlockingList(account: account),
    );
    if (!_isCurrent(generation)) return;
    switch (result) {
      case Success<KeywordBlockingListReply>(:final response):
        state.value = KeywordBlockSnapshot(
          loadingState: Success(
            List<KeywordBlockingItem>.unmodifiable(
              response.items.map((item) => item.deepCopy()),
            ),
          ),
          listLimit: response.listLimit,
          charLimit: response.charLimit,
        );
      case Error():
        state.value = KeywordBlockSnapshot(loadingState: result);
      case Loading():
        state.value = KeywordBlockSnapshot(
          loadingState: LoadingState<List<KeywordBlockingItem>?>.loading(),
        );
    }
  }

  Future<LoadingState<void>> add(String keyword) async {
    if (_disposed || !session.isActive) return const Error('当前操作不可用');
    _generation++;
    final result = await session.run(
      (account) => ImGrpc.keywordBlockingAdd(keyword, account: account),
    );
    if (!_isActive) return const Error('账号已切换');
    if (result case Success<void>()) {
      _generation++;
      final existing = state.value.loadingState.dataOrNull;
      if (existing != null) {
        state.value = KeywordBlockSnapshot(
          loadingState: Success(
            List<KeywordBlockingItem>.unmodifiable([
              ...existing.where((item) => item.keyword != keyword),
              KeywordBlockingItem(keyword: keyword),
            ]),
          ),
          listLimit: state.value.listLimit,
          charLimit: state.value.charLimit,
        );
      } else {
        await refresh();
      }
      session.notifyChanged(MessagingChangeKind.settings);
    }
    return result;
  }

  Future<LoadingState<void>> remove(String keyword) async {
    if (_disposed || !session.isActive) return const Error('当前操作不可用');
    _generation++;
    final result = await session.run(
      (account) => ImGrpc.keywordBlockingDelete(keyword, account: account),
    );
    if (!_isActive) return const Error('账号已切换');
    if (result case Success<void>()) {
      _generation++;
      final existing = state.value.loadingState.dataOrNull;
      if (existing != null) {
        state.value = KeywordBlockSnapshot(
          loadingState: Success(
            List<KeywordBlockingItem>.unmodifiable(
              existing.where((item) => item.keyword != keyword),
            ),
          ),
          listLimit: state.value.listLimit,
          charLimit: state.value.charLimit,
        );
      } else {
        await refresh();
      }
      session.notifyChanged(MessagingChangeKind.settings);
    }
    return result;
  }

  bool _isCurrent(int generation) =>
      !_disposed && session.isActive && generation == _generation;

  bool get _isActive => !_disposed && session.isActive;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    state.dispose();
  }
}

@immutable
class ConversationSettingsSnapshot {
  const ConversationSettingsSnapshot({
    required this.userState,
    required this.sessionSs,
    required this.msgDnd,
    this.isPinned = false,
  });

  final LoadingState<List<ImUserInfosData>?> userState;
  final LoadingState<SessionSsData> sessionSs;
  final LoadingState<List<UidSetting>?> msgDnd;
  final bool isPinned;
}

class ConversationSettingsHandle {
  ConversationSettingsHandle({
    required this.session,
    required this.talkerUid,
  }) : state = ValueNotifier(
         ConversationSettingsSnapshot(
           userState: LoadingState<List<ImUserInfosData>?>.loading(),
           sessionSs: LoadingState<SessionSsData>.loading(),
           msgDnd: LoadingState<List<UidSetting>?>.loading(),
         ),
       );

  final MessagingSession session;
  final int talkerUid;
  final ValueNotifier<ConversationSettingsSnapshot> state;
  int _userGeneration = 0;
  int _sessionGeneration = 0;
  int _dndGeneration = 0;
  int _pinGeneration = 0;
  int _pushWriteVersion = 0;
  int _muteWriteVersion = 0;
  int _pinWriteVersion = 0;
  int _blockWriteVersion = 0;
  bool _disposed = false;

  Future<void> refresh() async {
    if (_disposed || !session.isActive) return;
    await Future.wait([
      getUserInfo(),
      getSessionSs(),
      getMsgDnd(),
      getIsPinned(),
    ]);
  }

  Future<void> getUserInfo() async {
    final generation = ++_userGeneration;
    final result = await session.run(
      (account) => MsgHttp.imUserInfos(
        uids: talkerUid.toString(),
        account: account,
      ),
    );
    if (!_isCurrent(_userGeneration, generation)) return;
    state.value = _copy(userState: _mapLoadingState(result, _copyUser));
  }

  Future<void> getSessionSs() async {
    final generation = ++_sessionGeneration;
    final result = await session.run(
      (account) => MsgHttp.getSessionSs(
        talkerUid: talkerUid,
        account: account,
      ),
    );
    if (!_isCurrent(_sessionGeneration, generation)) return;
    state.value = _copy(sessionSs: _mapLoadingState(result, _copySessionSs));
  }

  Future<void> getMsgDnd() async {
    final generation = ++_dndGeneration;
    final result = await session.run(
      (account) => MsgHttp.getMsgDnd(
        uidsStr: talkerUid,
        account: account,
      ),
    );
    if (!_isCurrent(_dndGeneration, generation)) return;
    state.value = _copy(msgDnd: _mapLoadingState(result, _copyDnd));
  }

  Future<void> getIsPinned() async {
    final generation = ++_pinGeneration;
    final result = await session.run(
      (account) => ImGrpc.sessionUpdate(
        sessionId: _sessionId,
        account: account,
      ),
    );
    if (!_isCurrent(_pinGeneration, generation)) return;
    if (result case Success<SessionUpdateReply>(:final response)) {
      state.value = _copy(isPinned: response.session.isPinned);
    }
  }

  Future<LoadingState<void>> setPush(bool receivesPush) async {
    if (_disposed || !session.isActive) return const Error('当前操作不可用');
    final setting = receivesPush ? 1 : 0;
    final version = ++_pushWriteVersion;
    _sessionGeneration++;
    final result = await session.run(
      (account) => MsgHttp.setPushSs(
        setting: setting,
        talkerUid: talkerUid,
        account: account,
      ),
    );
    if (!_isActive) return const Error('账号已切换');
    if (result case Success<void>() when version == _pushWriteVersion) {
      _sessionGeneration++;
      final current = state.value.sessionSs.dataOrNull;
      if (current != null) {
        state.value = _copy(
          sessionSs: Success(_copySessionSs(current)..pushSetting = setting),
        );
      }
      session.notifyChanged(MessagingChangeKind.settings, talkerId: talkerUid);
    } else if (version == _pushWriteVersion) {
      _sessionGeneration++;
    }
    return result;
  }

  Future<LoadingState<void>> setPinned() async {
    if (_disposed || !session.isActive) return const Error('当前操作不可用');
    final next = !state.value.isPinned;
    final version = ++_pinWriteVersion;
    _pinGeneration++;
    final result = await session.run(
      (account) async => _asVoid(
        next
            ? await ImGrpc.pinSession(
                sessionId: _sessionId,
                account: account,
              )
            : await ImGrpc.unpinSession(
                sessionId: _sessionId,
                account: account,
              ),
      ),
    );
    if (!_isActive) return const Error('账号已切换');
    if (result case Success<void>() when version == _pinWriteVersion) {
      _pinGeneration++;
      state.value = _copy(isPinned: next);
      session.notifyChanged(
        MessagingChangeKind.conversation,
        talkerId: talkerUid,
      );
    } else if (version == _pinWriteVersion) {
      _pinGeneration++;
    }
    return result;
  }

  Future<LoadingState<void>> setMuted(bool isMuted) async {
    if (_disposed || !session.isActive) return const Error('当前操作不可用');
    final setting = isMuted ? 0 : 1;
    final version = ++_muteWriteVersion;
    _dndGeneration++;
    final result = await session.run(
      (account) => MsgHttp.setMsgDnd(
        uid: account.mid,
        setting: setting,
        dndUid: talkerUid,
        account: account,
      ),
    );
    if (!_isActive) return const Error('账号已切换');
    if (result case Success<void>() when version == _muteWriteVersion) {
      _dndGeneration++;
      final current = state.value.msgDnd.dataOrNull;
      if (current != null && current.isNotEmpty) {
        final updated = _copyDnd(current)!;
        updated.first.setting = setting;
        state.value = _copy(msgDnd: Success(updated));
      }
      session.notifyChanged(
        MessagingChangeKind.conversation,
        talkerId: talkerUid,
      );
    } else if (version == _muteWriteVersion) {
      _dndGeneration++;
    }
    return result;
  }

  Future<LoadingState<void>> setBlocked(bool isBlocked) async {
    if (_disposed || !session.isActive) return const Error('当前操作不可用');
    final version = ++_blockWriteVersion;
    _sessionGeneration++;
    final result = await session.run(
      (account) => VideoHttp.relationMod(
        mid: talkerUid,
        act: isBlocked ? 6 : 5,
        reSrc: 11,
        account: account,
      ),
    );
    if (!_isActive) return const Error('账号已切换');
    if (result case Success<void>() when version == _blockWriteVersion) {
      _sessionGeneration++;
      final current = state.value.sessionSs.dataOrNull;
      if (current != null) {
        state.value = _copy(
          sessionSs: Success(
            _copySessionSs(current)..followStatus = isBlocked ? null : 128,
          ),
        );
      }
      session.notifyChanged(
        MessagingChangeKind.conversation,
        talkerId: talkerUid,
      );
    } else if (version == _blockWriteVersion) {
      _sessionGeneration++;
    }
    return result;
  }

  SessionId get _sessionId => SessionId(
    privateId: PrivateId(talkerUid: Int64(talkerUid)),
  );

  ConversationSettingsSnapshot _copy({
    LoadingState<List<ImUserInfosData>?>? userState,
    LoadingState<SessionSsData>? sessionSs,
    LoadingState<List<UidSetting>?>? msgDnd,
    bool? isPinned,
  }) => ConversationSettingsSnapshot(
    userState: userState ?? state.value.userState,
    sessionSs: sessionSs ?? state.value.sessionSs,
    msgDnd: msgDnd ?? state.value.msgDnd,
    isPinned: isPinned ?? state.value.isPinned,
  );

  static LoadingState<T> _mapLoadingState<T>(
    LoadingState<T> state,
    T Function(T) copy,
  ) => switch (state) {
    Success<T>(:final response) => Success(copy(response)),
    Error() => state,
    Loading() => state,
  };

  static List<ImUserInfosData>? _copyUser(List<ImUserInfosData>? items) => items
      ?.map(
        (item) => ImUserInfosData(
          mid: item.mid,
          name: item.name,
          face: item.face,
          sign: item.sign,
          vip: item.vip == null
              ? null
              : Vip.fromJson({
                  'type': item.vip!.type,
                  'status': item.vip!.status,
                  'label': item.vip!.label == null
                      ? null
                      : {'text': item.vip!.label!.text},
                }),
          pendant: item.pendant == null
              ? null
              : Pendant.fromJson({'image': item.pendant!.image}),
          official: item.official == null
              ? null
              : BaseOfficialVerify.fromJson({
                  'type': item.official!.type,
                  'desc': item.official!.desc,
                }),
        ),
      )
      .toList(growable: false);

  static SessionSsData _copySessionSs(SessionSsData item) => SessionSsData(
    followStatus: item.followStatus,
    pushSetting: item.pushSetting,
    showPushSetting: item.showPushSetting,
  );

  static List<UidSetting>? _copyDnd(List<UidSetting>? items) => items
      ?.map((item) => UidSetting(setting: item.setting))
      .toList(growable: false);

  bool get _isActive => !_disposed && session.isActive;
  bool _isCurrent(int currentGeneration, int generation) =>
      _isActive && currentGeneration == generation;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _userGeneration++;
    _sessionGeneration++;
    _dndGeneration++;
    _pinGeneration++;
    state.dispose();
  }
}

LoadingState<void> _asVoid<T>(LoadingState<T> result) => switch (result) {
  Success<T>() => const Success(null),
  Error(:final errMsg, :final code) => Error(errMsg, code: code),
  Loading() => LoadingState<void>.loading(),
};

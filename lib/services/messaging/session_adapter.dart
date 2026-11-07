import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:pili_aurora/grpc/bilibili/app/im/v1.pb.dart' as pb;
import 'package:pili_aurora/grpc/bilibili/dagw/component/avatar/v1.pb.dart'
    as avatar;
import 'package:pili_aurora/grpc/bilibili/dagw/component/avatar/common.pb.dart'
    as avatar_common;
import 'package:pili_aurora/grpc/im.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/msg.dart';
import 'package:pili_aurora/services/messaging/session_models.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:protobuf/protobuf.dart' show PbMap;

class SessionPageCursor {
  const SessionPageCursor._(this.offsets);

  final PbMap<int, pb.Offset> offsets;
}

class SessionPageResult {
  SessionPageResult({
    required Iterable<SessionEntry> entries,
    required this.cursor,
    required this.hasMore,
    Iterable<SessionMenuItem> menuItems = const [],
    Iterable<SessionMenuItem> outsideItems = const [],
  }) : entries = List.unmodifiable(entries),
       menuItems = List.unmodifiable(menuItems),
       outsideItems = List.unmodifiable(outsideItems);

  final List<SessionEntry> entries;
  final SessionPageCursor? cursor;
  final bool hasMore;
  final List<SessionMenuItem> menuItems;
  final List<SessionMenuItem> outsideItems;
}

class SessionAdapter {
  const SessionAdapter();

  Future<LoadingState<SessionPageResult>> loadPage({
    required Account account,
    required SessionFolder folder,
    SessionPageCursor? cursor,
  }) async {
    if (folder == SessionFolder.home) {
      final result = await ImGrpc.sessionMain(
        offset: cursor?.offsets,
        account: account,
      );
      return _mapResult(result, (reply) {
        final page = reply.paginationParams;
        return SessionPageResult(
          entries: reply.sessions.map(_entryFromProto),
          cursor: page.offsets.isEmpty
              ? null
              : SessionPageCursor._(page.offsets),
          hasMore: page.hasMore,
          menuItems: reply.threeDotItems.map(_menuItemFromProto),
          outsideItems: reply.outsideItem.map(_menuItemFromProto),
        );
      });
    }

    final result = await ImGrpc.sessionSecondary(
      offset: cursor?.offsets,
      pageType: _pageType(folder),
      account: account,
    );
    return _mapResult(result, (reply) {
      final page = reply.paginationParams;
      return SessionPageResult(
        entries: reply.sessions.map(_entryFromProto),
        cursor: page.offsets.isEmpty ? null : SessionPageCursor._(page.offsets),
        hasMore: page.hasMore,
        menuItems: reply.threeDotItems.map(_menuItemFromProto),
      );
    });
  }

  Future<LoadingState<void>> remove({
    required Account account,
    required int talkerId,
  }) => MsgHttp.removeMsg(talkerId, account: account);

  Future<LoadingState<void>> setMuted({
    required Account account,
    required int talkerId,
    required bool isMuted,
  }) => MsgHttp.setMsgDnd(
    uid: account.mid,
    setting: isMuted ? 0 : 1,
    dndUid: Int64(talkerId),
    account: account,
  );

  Future<LoadingState<void>> setPinned({
    required Account account,
    required SessionKey key,
    required bool isPinned,
  }) {
    final id = _sessionId(key);
    return isPinned
        ? ImGrpc.unpinSession(sessionId: id, account: account)
        : ImGrpc.pinSession(sessionId: id, account: account);
  }

  Future<LoadingState<void>> clearUnread({
    required Account account,
    required SessionFolder folder,
  }) => ImGrpc.clearUnread(pageType: _pageType(folder), account: account);

  Future<LoadingState<void>> deleteList({
    required Account account,
    required SessionFolder folder,
  }) => ImGrpc.deleteSessionList(pageType: _pageType(folder), account: account);

  Future<LoadingState<void>> markRead({
    required Account account,
    required int talkerId,
  }) async {
    final detail = await ImGrpc.sessionDetail(
      talkerId: Int64(talkerId),
      sessionType: 1,
      account: account,
    );
    if (detail case Success(:final response)) {
      return MsgHttp.ackSessionMsg(
        talkerId: talkerId,
        ackSeqno: response.ackSeqno.toInt(),
        account: account,
      );
    }
    return detail;
  }

  static LoadingState<T> _mapResult<R, T>(
    LoadingState<R> result,
    T Function(R) map,
  ) => switch (result) {
    Success(:final response) => Success(map(response)),
    Error() => result,
    Loading() => result,
  };

  static SessionEntry _entryFromProto(pb.Session source) {
    final id = source.id;
    final key = _keyFromProto(source);
    final info = source.sessionInfo;
    final avatarInfo = _avatarFromProto(
      info.avatar,
      info.hasVipInfo() ? info.vipInfo : '',
    );
    final label =
        info.userLabel.hasStyle() &&
            info.userLabel.style.hasBorderedLabel() &&
            info.userLabel.style.borderedLabel.hasText()
        ? info.userLabel.style.borderedLabel.text
        : null;

    return SessionEntry(
      key: key,
      target: _targetFromProto(id),
      name: info.sessionName,
      summary: source.msgSummary.rawMsg,
      timestampMicros: source.hasTimestamp() ? source.timestamp.toInt() : null,
      unread: _unreadFromProto(source.unread),
      isPinned: source.isPinned,
      isMuted: source.isMuted,
      avatar: avatarInfo,
      isLive: info.isLive,
      userLabel: label,
      sequenceNumber: source.sequenceNumber.toInt(),
    );
  }

  static SessionKey _keyFromProto(pb.Session source) {
    final id = source.id;
    return switch (id.whichId()) {
      pb.SessionId_Id.privateId => SessionKey(
        kind: SessionKeyKind.private,
        primary: id.privateId.talkerUid.toInt(),
      ),
      pb.SessionId_Id.groupId => SessionKey(
        kind: SessionKeyKind.group,
        primary: id.groupId.groupId.toInt(),
      ),
      pb.SessionId_Id.foldId => SessionKey(
        kind: SessionKeyKind.fold,
        primary: id.foldId.type.value,
      ),
      pb.SessionId_Id.systemId => SessionKey(
        kind: SessionKeyKind.system,
        primary: id.systemId.type.value,
      ),
      pb.SessionId_Id.customerId => SessionKey(
        kind: SessionKeyKind.customer,
        primary: id.customerId.shopId.toInt(),
        secondary: id.customerId.shopType.toInt(),
      ),
      pb.SessionId_Id.notSet => SessionKey(
        kind: SessionKeyKind.unknown,
        primary: source.sequenceNumber.toInt(),
        secondary: source.timestamp.toInt(),
      ),
    };
  }

  static SessionTarget _targetFromProto(pb.SessionId id) =>
      switch (id.whichId()) {
        pb.SessionId_Id.privateId => PrivateSessionTarget(
          id.privateId.talkerUid.toInt(),
        ),
        pb.SessionId_Id.groupId => GroupSessionTarget(
          id.groupId.groupId.toInt(),
        ),
        pb.SessionId_Id.foldId => FoldSessionTarget(
          typeCode: id.foldId.type.value,
          folder: _folderForType(id.foldId.type),
        ),
        pb.SessionId_Id.systemId => SystemSessionTarget(
          id.systemId.type.value,
        ),
        pb.SessionId_Id.customerId => CustomerSessionTarget(
          shopId: id.customerId.shopId.toInt(),
          shopType: id.customerId.shopType.toInt(),
        ),
        pb.SessionId_Id.notSet => const FoldSessionTarget(typeCode: 0),
      };

  static SessionUnread _unreadFromProto(pb.Unread unread) =>
      switch (unread.style) {
        pb.UnreadStyle.UNREAD_STYLE_NONE => const SessionUnread(),
        pb.UnreadStyle.UNREAD_STYLE_DOT => const SessionUnread(
          style: SessionUnreadStyle.dot,
        ),
        pb.UnreadStyle.UNREAD_STYLE_NUMBER => SessionUnread(
          style: SessionUnreadStyle.number,
          number: unread.number.toInt(),
          numberLabel: unread.numberShow,
        ),
        _ => SessionUnread(
          style: SessionUnreadStyle.unknown,
          number: unread.number.toInt(),
          numberLabel: unread.numberShow,
        ),
      };

  static SessionAvatar _avatarFromProto(
    avatar.AvatarItem source,
    String vipInfo,
  ) {
    final layers = source.fallbackLayers.layers;
    final primary = layers.firstOrNull?.resource;
    final pendant = layers.elementAtOrNull(1)?.resource;
    final official = layers.lastOrNull?.resource;
    final vip = _readVip(vipInfo);
    return SessionAvatar(
      url: _resourceUrl(primary) ?? '',
      pendantUrl: _resourceUrl(pendant),
      officialType: _officialType(official),
      mid: source.hasMid() ? source.mid.toInt() : null,
      vipStatus: vip.$1,
      vipType: vip.$2,
    );
  }

  static (int?, int?) _readVip(String vipInfo) {
    if (vipInfo.isEmpty) return (null, null);
    try {
      final value = jsonDecode(vipInfo);
      if (value is! Map) return (null, null);
      return (
        value['status'] is num ? (value['status'] as num).toInt() : null,
        value['type'] is num ? (value['type'] as num).toInt() : null,
      );
    } on FormatException {
      return (null, null);
    }
  }

  static String? _resourceUrl(avatar.BasicLayerResource? resource) {
    if (resource == null) return null;
    if (resource.hasResImage()) {
      return _remoteUrl(resource.resImage.imageSrc);
    }
    if (resource.hasResAnimation()) {
      return _remoteUrl(resource.resAnimation.webpSrc);
    }
    if (resource.hasResNativeDraw()) {
      return _remoteUrl(resource.resNativeDraw.drawSrc);
    }
    return null;
  }

  static String? _remoteUrl(avatar_common.ResourceSource source) =>
      source.hasRemote() && source.remote.hasUrl() ? source.remote.url : null;

  static int? _officialType(avatar.BasicLayerResource? resource) {
    if (resource == null || !resource.hasResImage()) return null;
    final source = resource.resImage.imageSrc;
    if (!source.hasLocalValue()) return null;
    return switch (source.localValue) {
      3 => 0,
      4 => 1,
      _ => null,
    };
  }

  static SessionFolder? _folderForType(pb.SessionType type) => switch (type) {
    pb.SessionType.SESSION_TYPE_UNKNOWN => SessionFolder.unknown,
    pb.SessionType.SESSION_TYPE_GROUP => SessionFolder.group,
    pb.SessionType.SESSION_TYPE_GROUP_FOLD => SessionFolder.group,
    pb.SessionType.SESSION_TYPE_UNFOLLOWED => SessionFolder.unfollowed,
    pb.SessionType.SESSION_TYPE_STRANGER => SessionFolder.stranger,
    pb.SessionType.SESSION_TYPE_DUSTBIN => SessionFolder.dustbin,
    pb.SessionType.SESSION_TYPE_CUSTOMER_FOLD => SessionFolder.customer,
    pb.SessionType.SESSION_TYPE_AI_FOLD => SessionFolder.ai,
    pb.SessionType.SESSION_TYPE_CUSTOMER_ACCOUNT => SessionFolder.customer,
    _ => null,
  };

  static pb.SessionPageType _pageType(SessionFolder folder) => switch (folder) {
    SessionFolder.home => pb.SessionPageType.SESSION_PAGE_TYPE_HOME,
    SessionFolder.unknown => pb.SessionPageType.SESSION_PAGE_TYPE_UNKNOWN,
    SessionFolder.unfollowed => pb.SessionPageType.SESSION_PAGE_TYPE_UNFOLLOWED,
    SessionFolder.stranger => pb.SessionPageType.SESSION_PAGE_TYPE_STRANGER,
    SessionFolder.dustbin => pb.SessionPageType.SESSION_PAGE_TYPE_DUSTBIN,
    SessionFolder.group => pb.SessionPageType.SESSION_PAGE_TYPE_GROUP,
    SessionFolder.huahuo => pb.SessionPageType.SESSION_PAGE_TYPE_HUA_HUO,
    SessionFolder.ai => pb.SessionPageType.SESSION_PAGE_TYPE_AI,
    SessionFolder.customer => pb.SessionPageType.SESSION_PAGE_TYPE_CUSTOMER,
  };

  static SessionMenuItem _menuItemFromProto(pb.ThreeDotItem item) =>
      SessionMenuItem(
        title: item.title,
        iconUrl: item.icon,
        url: item.url,
        hasRedDot: item.hasRedDot,
        action: switch (item.type) {
          pb.ThreeDotItemType.THREE_DOT_ITEM_TYPE_MSG_SETTING =>
            SessionMenuAction.messageSettings,
          pb.ThreeDotItemType.THREE_DOT_ITEM_TYPE_READ_ALL =>
            SessionMenuAction.readAll,
          pb.ThreeDotItemType.THREE_DOT_ITEM_TYPE_CLEAR_LIST =>
            SessionMenuAction.clearList,
          pb.ThreeDotItemType.THREE_DOT_ITEM_TYPE_UP_HELPER =>
            SessionMenuAction.upHelper,
          pb.ThreeDotItemType.THREE_DOT_ITEM_TYPE_CONTACTS =>
            SessionMenuAction.contacts,
          pb.ThreeDotItemType.THREE_DOT_ITEM_TYPE_FANS_GROUP_HELPER =>
            SessionMenuAction.fansGroupHelper,
          _ => SessionMenuAction.other,
        },
      );

  static pb.SessionId _sessionId(SessionKey key) => switch (key.kind) {
    SessionKeyKind.private => pb.SessionId(
      privateId: pb.PrivateId(talkerUid: Int64(key.primary)),
    ),
    SessionKeyKind.group => pb.SessionId(
      groupId: pb.GroupId(groupId: Int64(key.primary)),
    ),
    SessionKeyKind.fold => pb.SessionId(
      foldId: pb.FoldId(type: pb.SessionType.valueOf(key.primary)),
    ),
    SessionKeyKind.system => pb.SessionId(
      systemId: pb.SystemId(type: pb.SessionType.valueOf(key.primary)),
    ),
    SessionKeyKind.customer => pb.SessionId(
      customerId: pb.CustomerId(
        shopId: Int64(key.primary),
        shopType: Int64(key.secondary),
      ),
    ),
    SessionKeyKind.unknown => pb.SessionId(),
  };
}

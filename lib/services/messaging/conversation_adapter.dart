import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:pili_aurora/grpc/bilibili/im/interfaces/v1.pb.dart'
    show EmotionInfo, RspSessionMsg;
import 'package:pili_aurora/grpc/bilibili/im/type.pb.dart' show Msg, MsgType;
import 'package:pili_aurora/grpc/im.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/msg.dart';
import 'package:pili_aurora/models/remote/upload_bfs/data.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:mime/mime.dart';

abstract interface class ConversationAdapter {
  Future<LoadingState<ConversationPage>> latest(
    Account account,
    ConversationTarget target,
  );

  Future<LoadingState<ConversationPage>> older(
    Account account,
    ConversationTarget target,
    int cursor,
  );

  Future<LoadingState<void>> send(
    Account account,
    ConversationTarget target,
    MessageContent content,
  );

  Future<LoadingState<UploadedMessageImage>> uploadImage(
    Account account,
    String path,
  );

  Future<LoadingState<void>> recall(
    Account account,
    ConversationTarget target,
    int messageKey,
  );

  Future<LoadingState<void>> acknowledge(
    Account account,
    ConversationTarget target,
    int sequence,
  );

  Future<LoadingState<void>> report(
    Account account,
    Message message,
    int reasonType,
    String reasonDescription,
  );
}

/// 协议边界：在此处转换 protobuf 和传输 JSON，使会话与界面只交换不可变 Dart 值。
final class GrpcConversationAdapter implements ConversationAdapter {
  const GrpcConversationAdapter();

  @override
  Future<LoadingState<ConversationPage>> latest(
    Account account,
    ConversationTarget target,
  ) async {
    if (!_supportsTarget(target)) return _unsupportedTarget();
    final result = await ImGrpc.syncFetchSessionMsgs(
      account: account,
      talkerId: target.talkerId,
    );
    return _mapPage(result, target);
  }

  @override
  Future<LoadingState<ConversationPage>> older(
    Account account,
    ConversationTarget target,
    int cursor,
  ) async {
    if (!_supportsTarget(target)) return _unsupportedTarget();
    final result = await ImGrpc.syncFetchSessionMsgs(
      account: account,
      talkerId: target.talkerId,
      beginSeqno: Int64.ZERO,
      endSeqno: Int64(cursor),
    );
    return _mapPage(result, target);
  }

  @override
  Future<LoadingState<void>> send(
    Account account,
    ConversationTarget target,
    MessageContent content,
  ) async {
    if (!_supportsTarget(target)) return _unsupportedTarget();
    final (type, wireContent) = switch (content) {
      TextMessageContent(:final text) => (
        MsgType.EN_MSG_TYPE_TEXT,
        jsonEncode({'content': text}),
      ),
      ImageMessageContent(
        :final url,
        :final width,
        :final height,
        :final imageType,
        :final original,
        :final size,
      ) =>
        (
          content.kind == MessageContentKind.customFace
              ? MsgType.EN_MSG_TYPE_CUSTOM_FACE
              : MsgType.EN_MSG_TYPE_PIC,
          jsonEncode({
            'url': url,
            'width': width,
            'height': height,
            'imageType': imageType,
            'original': original,
            'size': size,
          }),
        ),
      StructuredMessageContent(:final kind, :final payload)
          when kind == MessageContentKind.shareV2 ||
              kind == MessageContentKind.commonShareCard =>
        (
          kind == MessageContentKind.shareV2
              ? MsgType.EN_MSG_TYPE_SHARE_V2
              : MsgType.EN_MSG_TYPE_COMMON_SHARE_CARD,
          jsonEncode(payload),
        ),
      _ => (null, null),
    };
    if (type == null || wireContent == null) {
      return const Error('当前消息类型不能发送');
    }
    final result = await ImGrpc.sendMsg(
      account: account,
      senderUid: account.mid,
      receiverId: target.talkerId,
      content: wireContent,
      msgType: type,
    );
    return switch (result) {
      Success() => const Success(null),
      Error() => result,
      Loading() => const Error('发送状态未知'),
    };
  }

  @override
  Future<LoadingState<UploadedMessageImage>> uploadImage(
    Account account,
    String path,
  ) async {
    final result = await MsgHttp.uploadBfs(
      account: account,
      path: path,
      biz: 'im',
    );
    return switch (result) {
      Success<UploadBfsResData>(:final response) => switch ((
        response.imageUrl,
        response.imageWidth,
        response.imageHeight,
        response.imgSize,
      )) {
        (String url, int width, int height, double size) => Success(
          UploadedMessageImage(
            url: url,
            width: width,
            height: height,
            size: size.toInt(),
            imageType: lookupMimeType(path)?.split('/').last ?? 'jpg',
          ),
        ),
        _ => const Error('图片服务返回的数据不完整'),
      },
      Error() => result,
      Loading() => const Error('图片上传状态未知'),
    };
  }

  @override
  Future<LoadingState<void>> recall(
    Account account,
    ConversationTarget target,
    int messageKey,
  ) async {
    if (!_supportsTarget(target)) return _unsupportedTarget();
    final result = await ImGrpc.sendMsg(
      account: account,
      senderUid: account.mid,
      receiverId: target.talkerId,
      content: '$messageKey',
      msgType: MsgType.EN_MSG_TYPE_DRAW_BACK,
    );
    return switch (result) {
      Success() => const Success(null),
      Error() => result,
      Loading() => const Error('撤回状态未知'),
    };
  }

  @override
  Future<LoadingState<void>> acknowledge(
    Account account,
    ConversationTarget target,
    int sequence,
  ) {
    if (!_supportsTarget(target)) return Future.value(_unsupportedTarget());
    return MsgHttp.ackSessionMsg(
      account: account,
      talkerId: target.talkerId,
      ackSeqno: sequence,
    );
  }

  @override
  Future<LoadingState<void>> report(
    Account account,
    Message message,
    int reasonType,
    String reasonDescription,
  ) => MsgHttp.imMsgReport(
    account: account,
    accusedUid: message.senderId,
    reasonType: reasonType,
    reasonDesc: reasonDescription,
    comment: {'group_id': 0, 'msg_key': message.messageKey.toString()},
    extra: const {'msg_keys': []},
  );

  bool _supportsTarget(ConversationTarget target) =>
      target.sessionType == 1 && target.talkerId > 0;

  Error _unsupportedTarget() => const Error('当前消息接口仅支持有效的一对一会话');

  LoadingState<ConversationPage> _mapPage(
    LoadingState<RspSessionMsg> response,
    ConversationTarget target,
  ) => switch (response) {
    Success<RspSessionMsg>(:final response) => Success(
      ConversationPage(
        messages: response.messages.map(
          (message) => _messageFromProto(target, message),
        ),
        hasOlder: response.hasMore != 0,
        cursor: _cursor(response.messages),
        emotions: response.eInfos.map(_emotionFromProto),
      ),
    ),
    Error() => response,
    Loading() => const Error('消息读取状态未知'),
  };

  int? _cursor(Iterable<Msg> messages) {
    int? cursor;
    for (final message in messages) {
      final sequence = message.msgSeqno.toInt();
      if (sequence > 0 && (cursor == null || sequence < cursor)) {
        cursor = sequence;
      }
    }
    return cursor;
  }

  Message _messageFromProto(ConversationTarget target, Msg value) {
    final decoded = _decodeJson(value.content);
    final recallTargetKey = value.msgType == MsgType.EN_MSG_TYPE_DRAW_BACK.value
        ? _recallTarget(decoded, value.content)
        : null;
    final messageKey = value.msgKey.toInt();
    final sequence = value.msgSeqno.toInt();
    final rawHash = value.content.hashCode;
    return Message(
      id: messageKey > 0
          ? '${target.talkerId}:key:$messageKey'
          : sequence > 0
          ? '${target.talkerId}:seq:$sequence'
          : '${target.talkerId}:${value.senderUid}:${value.timestamp}:$rawHash',
      messageKey: messageKey,
      sequence: sequence,
      senderId: value.senderUid.toInt(),
      timestamp: value.timestamp.toInt(),
      type: value.msgType,
      source: value.msgSource,
      content: _content(value.msgType, decoded, value.content),
      recalled: value.msgStatus == 1,
      recallTargetKey: recallTargetKey,
    );
  }

  EmotionSticker _emotionFromProto(EmotionInfo value) => EmotionSticker(
    text: value.text,
    url: value.hasGifUrl() ? value.gifUrl : value.url,
    size: value.size * 22.0,
  );

  MessageContent _content(int type, Object? value, String raw) {
    final map = value is Map<String, Object?> ? value : null;
    if (map == null) return UnknownMessageContent(messageType: type, raw: raw);
    if (type == MsgType.EN_MSG_TYPE_TEXT.value && map['content'] is String) {
      return TextMessageContent(map['content']! as String);
    }
    if (type == MsgType.EN_MSG_TYPE_PIC.value ||
        type == MsgType.EN_MSG_TYPE_CUSTOM_FACE.value) {
      final width = map['width'];
      final height = map['height'];
      final url = map['url'];
      if (url is String &&
          width is num &&
          width.isFinite &&
          width > 0 &&
          height is num &&
          height.isFinite &&
          height > 0) {
        return ImageMessageContent(
          url: url,
          width: width.toDouble(),
          height: height.toDouble(),
          imageType: map['imageType'] is String
              ? map['imageType']! as String
              : 'jpg',
          original: map['original'] is num
              ? (map['original']! as num).toInt()
              : 1,
          size: map['size'] is num ? (map['size']! as num).toInt() : 0,
          customFace: type == MsgType.EN_MSG_TYPE_CUSTOM_FACE.value,
        );
      }
      return UnknownMessageContent(messageType: type, raw: raw);
    }

    final kind = switch (type) {
      10 => MessageContentKind.notify,
      13 => MessageContentKind.pictureCard,
      18 => MessageContentKind.tip,
      7 => MessageContentKind.shareV2,
      11 => MessageContentKind.videoCard,
      12 => MessageContentKind.articleCard,
      14 => MessageContentKind.commonShareCard,
      16 => MessageContentKind.legacyCard,
      _ => MessageContentKind.unknown,
    };
    if (kind == MessageContentKind.unknown) {
      return UnknownMessageContent(messageType: type, raw: raw);
    }
    if (kind == MessageContentKind.tip) {
      final nested = map['content'] is String
          ? _decodeJson(map['content']! as String)
          : map['content'];
      if (nested is! List ||
          !nested.every(
            (item) => item is Map && item['text'] is String,
          )) {
        return UnknownMessageContent(messageType: type, raw: raw);
      }
      return StructuredMessageContent(kind, {...map, 'content': nested});
    }
    if (!_isValidCard(kind, map)) {
      return UnknownMessageContent(messageType: type, raw: raw);
    }
    return StructuredMessageContent(kind, map);
  }

  bool _isValidCard(MessageContentKind kind, Map<String, Object?> value) {
    bool optionalString(String key) =>
        value[key] == null || value[key] is String;
    bool identifier(Object? item) =>
        item is int || item is String && int.tryParse(item) != null;

    return switch (kind) {
      MessageContentKind.notify =>
        value['title'] is String &&
            optionalString('text') &&
            optionalString('jump_uri') &&
            optionalString('jump_text') &&
            optionalString('jump_uri_2') &&
            optionalString('jump_text_2') &&
            optionalString('jump_uri_3') &&
            optionalString('jump_text_3') &&
            (value['modules'] == null ||
                value['modules'] is List &&
                    (value['modules']! as List).every(
                      (module) =>
                          module is Map &&
                          module['title'] is String &&
                          module['detail'] is String,
                    )),
      MessageContentKind.pictureCard =>
        value['pic_url'] is String && optionalString('jump_url'),
      MessageContentKind.shareV2 =>
        value['source'] is int &&
            value['thumb'] is String &&
            optionalString('title') &&
            optionalString('headline') &&
            optionalString('author') &&
            (value['id'] == null || identifier(value['id'])) &&
            (value['bvid'] == null || value['bvid'] is String) &&
            switch (value['source']! as int) {
              2 || 6 || 11 || 16 => identifier(value['id']),
              5 => identifier(value['id']) || value['bvid'] is String,
              _ => true,
            },
      MessageContentKind.videoCard =>
        value['bvid'] is String &&
            value['cover'] is String &&
            value['times'] is num &&
            (value['times']! as num).isFinite &&
            (value['times']! as num) >= 0 &&
            value['title'] is String &&
            (value['attach_msg'] == null ||
                value['attach_msg'] is Map &&
                    (value['attach_msg']! as Map)['content'] is String),
      MessageContentKind.articleCard =>
        identifier(value['rid']) &&
            optionalString('title') &&
            optionalString('summary') &&
            value['image_urls'] is List &&
            (value['image_urls']! as List).every((url) => url is String),
      MessageContentKind.commonShareCard =>
        value['source'] == '直播' &&
            identifier(value['sourceID']) &&
            value['cover'] is String &&
            value['title'] is String &&
            value['author'] is String,
      MessageContentKind.legacyCard =>
        value['main_title'] is String &&
            value['sub_cards'] is List &&
            (value['sub_cards']! as List).every(
              (card) =>
                  card is Map &&
                  card['cover_url'] is String &&
                  card['jump_url'] is String &&
                  card['field1'] is String &&
                  card['field2'] is String &&
                  card['field3'] is String,
            ),
      _ => false,
    };
  }

  int? _recallTarget(Object? decoded, String raw) {
    if (decoded is Map) {
      final value = decoded['msg_key'] ?? decoded['msgKey'];
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
    }
    if (decoded is String) return int.tryParse(decoded);
    return int.tryParse(raw);
  }

  Object? _decodeJson(String raw) {
    try {
      return _freeze(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Object? _freeze(Object? value) => switch (value) {
    Map map => Map<String, Object?>.unmodifiable({
      for (final entry in map.entries)
        if (entry.key is String) entry.key as String: _freeze(entry.value),
    }),
    List list => List<Object?>.unmodifiable(list.map(_freeze)),
    _ => value,
  };
}

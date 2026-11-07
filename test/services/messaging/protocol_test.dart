import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/grpc/bilibili/im/interfaces/v1.pb.dart';
import 'package:pili_aurora/grpc/bilibili/im/type.pbenum.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/grpc/im.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/msg.dart';
import 'package:pili_aurora/models/remote/msg/msg_sys/data.dart';
import 'package:pili_aurora/services/messaging/conversation_adapter.dart';
import 'package:pili_aurora/services/messaging/feed.dart';
import 'package:pili_aurora/services/messaging/feed_adapters.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/utils/storage.dart';

import 'messaging_fixtures.dart';

void main() {
  late MessagingSession session;
  late RequestOptions captured;

  setUpAll(() async {
    GStorage.setting = await Hive.openBox('setting', bytes: Uint8List(0));
    Request();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
  });
  setUp(() {
    session = sessionFixture();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options;
            handler.resolve(
              Response(
                requestOptions: options,
                headers: Headers.fromMap({
                  'grpc-status': ['0'],
                }),
                data: GrpcReq.compressProtobuf(RspSendMsg().writeToBuffer()),
              ),
            );
          },
        ),
      );
  });
  tearDown(() => session.dispose());

  test('发送请求绑定账号并关闭自动重试', () async {
    final result = await ImGrpc.sendMsg(
      account: session.account,
      senderUid: 123,
      receiverId: 456,
      content: jsonEncode({'content': 'test'}),
    );
    expect(result.isSuccess, isTrue);
    expect(captured.extra['noRetry'], isTrue);
    expect(captured.extra['account'], same(session.account));
  });

  test('消息设置请求使用指定账号及其 CSRF', () async {
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options;
            handler.resolve(
              Response(requestOptions: options, data: {'code': 0}),
            );
          },
        ),
      );
    final result = await MsgHttp.setMsgDnd(
      account: session.account,
      uid: 123,
      setting: 1,
      dndUid: 456,
    );
    expect(result.isSuccess, isTrue);
    expect(captured.extra['account'], same(session.account));
    expect(captured.extra['noRetry'], isTrue);
    expect((captured.data as Map)['csrf'], session.account.csrf);
  });

  for (final kind in [
    MessageContentKind.shareV2,
    MessageContentKind.commonShareCard,
  ]) {
    test('分享卡片 $kind 保留协议字段并绑定账号', () async {
      final payload = <String, Object?>{
        'source': kind == MessageContentKind.shareV2 ? 5 : '直播',
        'id': 1234,
        'title': 'test',
        'thumb': 'https://example.invalid/cover.png',
      };
      final result = await const GrpcConversationAdapter().send(
        session.account,
        const ConversationTarget(talkerId: 456),
        StructuredMessageContent(kind, payload),
      );
      expect(result.isSuccess, isTrue);
      final request = ReqSendMsg.fromBuffer(
        GrpcReq.decompressProtobuf(captured.data as Uint8List),
      );
      expect(captured.extra['account'], same(session.account));
      expect(captured.extra['noRetry'], isTrue);
      expect(request.msg.senderUid.toInt(), 123);
      expect(request.msg.receiverId.toInt(), 456);
      expect(
        request.msg.msgType,
        kind == MessageContentKind.shareV2
            ? MsgType.EN_MSG_TYPE_SHARE_V2.value
            : MsgType.EN_MSG_TYPE_COMMON_SHARE_CARD.value,
      );
      expect(jsonDecode(request.msg.content), payload);
    });
  }

  test('系统消息先展示，ACK 超时保留数据且刷新可重试', () async {
    var acknowledgementAttempts = 0;
    var unreadChanges = 0;
    final unreadConfirmed = Completer<void>();
    final subscription = session.changes.listen((change) {
      if (change.kind == MessagingChangeKind.unread) {
        unreadChanges++;
        unreadConfirmed.complete();
      }
    });
    addTearDown(subscription.cancel);
    final acknowledgement = Completer<void>();
    final acknowledgementStarted = Completer<void>();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == Api.msgSysNotify) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'code': 0,
                    'data': [
                      {'id': 1, 'cursor': 1},
                    ],
                  },
                ),
              );
            } else {
              expect(options.path, Api.msgSysUpdateCursor);
              acknowledgementAttempts++;
              if (acknowledgementAttempts == 1) {
                acknowledgementStarted.complete();
                acknowledgement.future.then(
                  (_) => handler.reject(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.receiveTimeout,
                    ),
                  ),
                );
              } else {
                handler.resolve(
                  Response(requestOptions: options, data: {'code': 0}),
                );
              }
            }
          },
        ),
      );
    final feed = FeedHandle<MsgSysItem>(
      session: session,
      request: MessagingFeedAdapters.system,
      idOf: (item) => item.id,
      acknowledge: MessagingFeedAdapters.acknowledgeSystem,
      notifyUnreadOnRefresh: true,
    );
    addTearDown(feed.dispose);
    await feed.refresh();
    await acknowledgementStarted.future.timeout(const Duration(seconds: 1));
    expect(acknowledgementAttempts, 1);
    expect(feed.state.value.loadingState.dataOrNull?.single.id, 1);
    acknowledgement.complete();
    await settle();
    expect(feed.state.value.loadingState.dataOrNull?.single.id, 1);
    expect(unreadChanges, 0);
    await feed.refresh();
    await unreadConfirmed.future.timeout(const Duration(seconds: 1));
    expect(acknowledgementAttempts, 2);
    expect(unreadChanges, 1);
  });
}

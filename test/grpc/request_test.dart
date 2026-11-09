import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/audio.dart';
import 'package:pili_aurora/grpc/bilibili/app/listener/v1.pb.dart'
    show ThumbUpReq_ThumbType;
import 'package:pili_aurora/grpc/bilibili/im/interfaces/v1.pb.dart';
import 'package:pili_aurora/grpc/bilibili/rpc.pb.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/retry_interceptor.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';
import 'package:pili_aurora/services/messaging/conversation.dart';
import 'package:pili_aurora/services/messaging/conversation_adapter.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:protobuf/well_known_types/google/protobuf/any.pb.dart';

import '../services/messaging/messaging_fixtures.dart';
import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Adapter adapter;
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(RetryInterceptor(Request.dio, 2, 0));
  });
  setUp(() {
    adapter = _Adapter();
    Request.dio.httpClientAdapter = adapter;
  });
  tearDownAll(() => Request.dio.close(force: true));

  Future<LoadingState<RspSendMsg>> request({
    GrpcCallKind kind = GrpcCallKind.query,
    Account? account,
    bool background = false,
    DanmakuWorkToken? token,
    Future<void> Function(RspSendMsg, DanmakuWorkLease)? consume,
  }) => GrpcReq.request(
    '/fixture',
    ReqSendMsg(),
    RspSendMsg.fromBuffer,
    kind: kind,
    account: account,
    isolate: background,
    danmakuWork: token != null,
    workToken: token,
    consume: consume,
  );

  test('查询网络失败与是否显式绑定账号无关，统一返回可诊断的失败结果', () async {
    adapter.failure = DioExceptionType.receiveTimeout;
    for (final account in <Account?>[null, const NoAccount()]) {
      final result = await request(account: account);
      expect(result, isA<Error>());
      expect(result, isNot(isA<UnknownResult>()));
      expect((result as Error).cause, isA<DioException>());
      expect(result.toString(), contains('超时'));
    }
    expect(adapter.requests, 2);
  });

  test('音频投币、三连和点赞不重试，传输失败返回待确认', () async {
    adapter.failure = DioExceptionType.connectionError;
    for (final action in <Future<LoadingState> Function()>[
      () => AudioGrpc.audioCoinAdd(
        oid: Int64.ONE,
        subId: [],
        itemType: 1,
        num: 1,
      ),
      () => AudioGrpc.audioTripleLike(oid: Int64.ONE, subId: [], itemType: 1),
      () => AudioGrpc.audioThumbUp(
        oid: Int64.ONE,
        subId: [],
        itemType: 1,
        type: ThumbUpReq_ThumbType.values.first,
      ),
    ]) {
      expect(await action(), isA<UnknownResult>());
      expect(adapter.last!.extra['noRetry'], isTrue);
    }
    expect(adapter.requests, 3);
  });

  test('查询继续使用有限重试，读取不会套用写入未知结果', () async {
    adapter.failure = DioExceptionType.connectionError;
    final result = await request();
    expect(result, isA<Error>());
    expect(result, isNot(isA<UnknownResult>()));
    expect(adapter.last!.extra['noRetry'], isFalse);
    expect(adapter.requests, 3);
  });

  for (final background in [false, true]) {
    test('损坏协议在后台模式 $background 保留原始原因，写入结果待确认', () async {
      adapter.body = GrpcReq.compressProtobuf(
        Uint8List.fromList([
          0xff,
          if (background) ...Uint8List(1 << 20),
        ]),
      );
      final query = await request(background: background);
      expect(query, isA<Error>());
      expect((query as Error).cause, isNotNull);
      expect(query.toString(), '响应数据解析失败，请重试');
      final mutation = await request(
        kind: GrpcCallKind.mutation,
        background: background,
      );
      expect(mutation, isA<UnknownResult>());
      expect((mutation as Error).cause, isNotNull);
    });
  }

  test('缺失状态、超时与不可用响应均不能将写入判为确定失败', () async {
    for (final status in <String?>[null, '4', '14']) {
      adapter.headers = {
        if (status != null) 'grpc-status': [status],
      };
      expect(await request(kind: GrpcCallKind.mutation), isA<UnknownResult>());
      final query = await request();
      expect(query, isNot(isA<UnknownResult>()));
      expect(query.toString(), isNotEmpty);
    }
  });

  test('状态详情保留业务拒绝码，无嵌套详情时展示顶层消息', () async {
    final rejection = Status(
      code: 2,
      message: 'outer',
      details: [
        Any(
          typeUrl: 'type.googleapis.com/bilibili.rpc.Status',
          value: Status(code: -101, message: '账号未登录').writeToBuffer(),
        ),
      ],
    );
    adapter.headers = {
      'grpc-status': ['2'],
      'grpc-status-details-bin': [
        base64Encode(rejection.writeToBuffer()).replaceAll('=', ''),
      ],
    };
    final result = await request(kind: GrpcCallKind.mutation);
    expect(result, const Error('账号未登录', code: -101));
    expect(result, isNot(isA<UnknownResult>()));

    adapter.headers = {
      'grpc-status': ['7'],
      'grpc-status-details-bin': [
        base64Encode(Status(code: 7, message: '没有权限').writeToBuffer()),
      ],
    };
    expect((await request()).toString(), '没有权限');
  });

  test('损坏状态详情保留可读消息与原因，不展示二进制或解析异常', () async {
    adapter.headers = {
      'grpc-status': ['7'],
      'grpc-message': [Uri.encodeComponent('访问被拒绝')],
      'grpc-status-details-bin': ['!invalid!'],
    };
    final result = await request();
    expect(result.toString(), '访问被拒绝');
    expect((result as Error).cause, isA<FormatException>());
    expect(result.code, 7);
  });

  test('其他类型的状态元数据不作为嵌套业务码解析', () async {
    adapter.headers = {
      'grpc-status': ['7'],
      'grpc-status-details-bin': [
        base64Encode(
          Status(
            code: 7,
            message: '没有权限',
            details: [
              Any(
                typeUrl: 'type.googleapis.com/google.rpc.ErrorInfo',
                value: [0xff],
              ),
            ],
          ).writeToBuffer(),
        ),
      ],
    };
    final result = await request();
    expect(result, const Error('没有权限', code: 7));
    expect((result as Error).cause, isNull);
  });

  test('消息发送的损坏响应沿会话转换为 unknown，发送锁正常释放', () async {
    final session = sessionFixture();
    final conversation = Conversation(
      session: session,
      target: const ConversationTarget(talkerId: 456),
      adapter: const GrpcConversationAdapter(),
    );
    adapter.body = Uint8List.fromList([0]);
    final sent = await conversation.sendText('synthetic');
    expect(sent.status, OperationStatus.unknown);
    expect(conversation.snapshot.isSending, isFalse);
    conversation.dispose();
    session.dispose();
  });

  test('消费期间取消返回失效结果，并归还全部弹幕额度', () async {
    final token = DanmakuWorkToken();
    final result = await request(
      token: token,
      consume: (_, _) async {
        token.cancel();
      },
    );
    expect(result, const Error('弹幕任务已失效'));
    expect(DanmakuWorkQuota.instance.snapshot['reservedBytes'], 0);
    expect(DanmakuWorkQuota.instance.snapshot['runningTasks'], 0);
  });

  test('一元响应拒绝超出声明帧长的尾部数据', () {
    expect(
      () => GrpcReq.decompressProtobuf(Uint8List.fromList([0, 0, 0, 0, 0, 1])),
      throwsFormatException,
    );
  });
}

class _Adapter implements HttpClientAdapter {
  int requests = 0;
  RequestOptions? last;
  DioExceptionType? failure;
  List<int> body = GrpcReq.compressProtobuf(RspSendMsg().writeToBuffer());
  Map<String, List<String>> headers = {
    'grpc-status': ['0'],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    last = options;
    if (failure != null) {
      throw DioException(
        requestOptions: options,
        type: failure!,
        error: const SocketException('synthetic'),
      );
    }
    return ResponseBody.fromBytes(body, 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

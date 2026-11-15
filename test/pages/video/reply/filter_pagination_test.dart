import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/grpc/reply.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/reply_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../../support/memory_box.dart';

class _Replies extends ReplyController<MainListReply> {
  _Replies() {
    mode = Mode.MAIN_LIST_HOT;
  }
  @override
  Object get sourceId => 1;
  @override
  List<ReplyInfo> getDataList(MainListReply response) => response.replies;
  @override
  Future<LoadingState<MainListReply>> customGetData() => ReplyGrpc.mainList(
    oid: 1,
    mode: mode,
    offset: paginationReply?.nextOffset,
    cursorNext: cursorNext,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final responses = Queue<Object>();
  final requests = <MainListReq>[];
  late _Replies controller;
  MainListReply page(
    int id, {
    bool blocked = true,
    int? next,
    bool end = false,
  }) => MainListReply(
    replies: [
      ReplyInfo(
        id: Int64(id),
        content: Content(message: blocked ? 'blocked' : 'allowed'),
      ),
    ],
    cursor: CursorReply(next: Int64(next ?? id), isEnd: end),
    subjectControl: SubjectControl(count: Int64(100)),
  );
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            requests.add(
              MainListReq.fromBuffer(GrpcReq.decompressProtobuf(options.data)),
            );
            var body = responses.removeFirst();
            if (body is Future<MainListReply>) body = await body;
            handler.resolve(
              Response(
                requestOptions: options,
                headers: Headers.fromMap({
                  'grpc-status': [body is MainListReply ? '0' : '13'],
                }),
                data: body is MainListReply
                    ? GrpcReq.compressProtobuf(body.writeToBuffer())
                    : null,
              ),
            );
          },
        ),
      );
  });
  setUp(() {
    responses.clear();
    requests.clear();
    Accounts.accountMode[AccountType.main.index] = const NoAccount();
    ReplyGrpc.replyRegExp = RegExp('blocked');
    ReplyGrpc.enableFilter = true;
    ReplyGrpc.antiGoodsReply = false;
    controller = _Replies();
  });
  tearDown(() => controller.onClose());
  tearDownAll(() => Request.dio.close(force: true));

  test(
    'keyword filtered first page continues with the server cursor',
    () async {
      responses.addAll([page(1), page(2, blocked: false, end: true)]);
      await controller.queryData();
      expect(requests.map((r) => r.cursor.next.toInt()), [0, 1]);
      expect(controller.loadingState.value.dataOrNull!.single.id.toInt(), 2);
      expect(controller.isEnd, isTrue);
    },
  );

  test('five filtered pages yield and allow explicit continuation', () async {
    responses.addAll([
      for (var i = 1; i <= 5; i++) page(i),
      page(6, blocked: false, end: true),
    ]);
    await controller.queryData();
    expect(requests, hasLength(5));
    expect(controller.loadingState.value.dataOrNull, isEmpty);
    expect(controller.canLoadMore, isTrue);
    await controller.onLoadMore();
    expect(requests, hasLength(6));
    expect(controller.loadingState.value.dataOrNull!.single.id.toInt(), 6);
  });

  test('repeated cursor stops automatic and manual pagination', () async {
    responses.addAll([page(1, next: 7), page(2, next: 7)]);
    await controller.queryData();
    expect(requests, hasLength(2));
    expect(controller.isEnd, isTrue);
    await controller.onLoadMore();
    expect(requests, hasLength(2));
  });

  test(
    'filtered middle page preserves existing replies and reads the next page',
    () async {
      responses.addAll([
        page(1, blocked: false),
        page(2),
        page(3, blocked: false, end: true),
      ]);
      await controller.queryData();
      expect(requests, hasLength(1));
      await controller.onLoadMore();
      expect(requests, hasLength(3));
      expect(
        controller.loadingState.value.dataOrNull!.map((r) => r.id.toInt()),
        [1, 3],
      );
    },
  );

  test('failed refill preserves the last cursor for retry', () async {
    responses.addAll([page(1), 'failure', page(2, blocked: false, end: true)]);
    await controller.queryData();
    expect(controller.loadingState.value.dataOrNull, isEmpty);
    expect(controller.canLoadMore, isTrue);
    await controller.onLoadMore();
    expect(requests.map((r) => r.cursor.next.toInt()), [0, 1, 1]);
    expect(controller.loadingState.value.dataOrNull!.single.id.toInt(), 2);
  });

  test(
    'account replacement prevents refill after a late filtered page',
    () async {
      final reply = Completer<MainListReply>();
      responses.add(reply.future);
      final query = controller.queryData();
      Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
      reply.complete(page(1));
      await query;
      expect(requests, hasLength(1));
      expect(controller.loadingState.value, isA<Loading>());
    },
  );
}

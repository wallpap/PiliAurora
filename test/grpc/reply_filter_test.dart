import 'package:dio/dio.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/grpc/reply.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MainListReply body;
  ReplyInfo reply(int id, String text, [List<ReplyInfo>? children]) =>
      ReplyInfo(
        id: Int64(id),
        content: Content(message: text),
        replies: children,
      );
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response(
                requestOptions: options,
                headers: Headers.fromMap({
                  'grpc-status': ['0'],
                }),
                data: GrpcReq.compressProtobuf(body.writeToBuffer()),
              ),
            );
          },
        ),
      );
  });
  setUp(() {
    ReplyGrpc.replyRegExp = RegExp('blocked');
    ReplyGrpc.enableFilter = true;
    ReplyGrpc.antiGoodsReply = true;
  });
  tearDownAll(() => Request.dio.close(force: true));

  Future<MainListReply> query() async => (await ReplyGrpc.mainList(
    account: const NoAccount(),
    oid: 1,
    mode: Mode.MAIN_LIST_HOT,
    offset: null,
    cursorNext: null,
  )).dataOrNull!;

  test(
    'top and ordinary replies filter keyword and goods child previews equally',
    () async {
      List<ReplyInfo> children() => [
        reply(2, 'blocked'),
        reply(3, Constants.goodsUrlPrefix),
        reply(4, 'allowed'),
      ];
      body = MainListReply(
        upTop: reply(1, 'allowed', children()),
        replies: [reply(5, 'allowed', children())],
      );
      final result = await query();
      expect(result.upTop.replies.map((r) => r.id.toInt()), [4]);
      expect(result.replies.single.replies.map((r) => r.id.toInt()), [4]);
    },
  );

  test(
    'blocked top reply is removed and disabled filters preserve children',
    () async {
      body = MainListReply(upTop: reply(1, 'blocked'));
      expect((await query()).hasUpTop(), isFalse);
      ReplyGrpc.enableFilter = ReplyGrpc.antiGoodsReply = false;
      body = MainListReply(upTop: reply(1, 'allowed', [reply(2, 'blocked')]));
      expect((await query()).upTop.replies.single.id.toInt(), 2);
    },
  );
}

import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/video/reply_reply/controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../../support/memory_box.dart';

class _RepliesController extends VideoReplyReplyController {
  _RepliesController(this.response, {super.id, super.dialog})
    : super(oid: 1, rpid: 2, replyType: 1);

  final LoadingState response;
  int? jumpedTo;

  @override
  void jumpToItem(int index) => jumpedTo = index;

  @override
  Future<LoadingState> customGetData() async => response;
}

void main() {
  setUpAll(() async {
    GStorage.localCache = MemoryBox();
    GStorage.setting = await Hive.openBox<dynamic>(
      'nested-reply-level',
      bytes: Uint8List(0),
    );
    await GStorage.setting.put(SettingBoxKey.minimumReplyUserLevel, 4);
  });
  tearDownAll(() => GStorage.setting.close());

  ReplyInfo reply(int id, int level) => ReplyInfo(
    id: Int64(id),
    member: Member(level: Int64(level)),
  );

  test('楼中楼按过滤后的索引定位，保留原评论上下文和服务端总数', () async {
    final root = reply(2, 1)
      ..count = Int64(2)
      ..replies.addAll([reply(10, 1), reply(20, 4)]);
    final controller = _RepliesController(
      Success(DetailListReply(root: root, cursor: CursorReply(isEnd: true))),
      id: 20,
    );
    addTearDown(controller.onClose);
    await controller.queryData();
    expect(controller.firstFloor.value, same(root));
    expect(controller.loadingState.value.dataOrNull!.single.id.toInt(), 20);
    expect(controller.count.value, 2);
    expect(controller.index.value, 0);
    expect(controller.jumpedTo, 0);
  });

  test('对话列表也过滤等级', () async {
    final controller = _RepliesController(
      Success(
        DialogListReply(
          replies: [reply(10, 3), reply(20, 6)],
          cursor: CursorReply(isEnd: true),
        ),
      ),
      dialog: 1,
    );
    addTearDown(controller.onClose);
    await controller.queryData();
    expect(controller.loadingState.value.dataOrNull!.single.id.toInt(), 20);
  });
}

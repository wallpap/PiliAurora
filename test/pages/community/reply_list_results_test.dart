import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/common/reply_controller.dart';
import 'package:pili_aurora/pages/video/reply_reply/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

class _Replies extends ReplyController<MainListReply> {
  final requests = <Completer<LoadingState<MainListReply>>>[];

  @override
  int get sourceId => 1;

  @override
  List<ReplyInfo> getDataList(MainListReply response) => response.replies;

  @override
  Future<LoadingState<MainListReply>> customGetData() {
    final response = Completer<LoadingState<MainListReply>>();
    requests.add(response);
    return response.future;
  }
}

class _NestedReplies extends VideoReplyReplyController {
  _NestedReplies()
    : super(
        id: null,
        oid: 1,
        rpid: 2,
        dialog: null,
        replyType: 1,
      );

  final requests = <Completer<LoadingState>>[];

  @override
  Future<LoadingState> customGetData() {
    final response = Completer<LoadingState>();
    requests.add(response);
    return response.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LoginAccount account(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  );
  ReplyInfo reply(int id, {List<ReplyInfo>? children}) => ReplyInfo(
    id: Int64(id),
    oid: Int64.ONE,
    type: Int64.ONE,
    replies: children,
  );
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.localCache = MemoryBox();
  });
  setUp(() => Accounts.accountMode[AccountType.main.index] = account('old'));

  test('评论按 ID 插入删除与去重，保留未知总数和当前父项', () {
    final controller = _Replies();
    addTearDown(controller.onDelete.call);
    final oldParent = reply(2);
    final currentParent = reply(2, children: [reply(3)])..count = Int64.ONE;
    final pinned = reply(1)..ensureReplyControl().isUpTop = true;
    final list = [pinned, currentParent];
    controller
      ..loadingState.value = Success(list)
      ..hasUpTop = true
      ..onReplyPublished(reply(4))
      ..onReplyPublished(reply(4));
    expect(list.map((item) => item.id.toInt()), [1, 4, 2]);
    controller
      ..onReplyPublished(reply(5), parent: oldParent)
      ..onReplyPublished(reply(5), parent: oldParent);
    expect(currentParent.replies.map((item) => item.id.toInt()), [3, 5]);
    expect(currentParent.count, Int64(2));
    controller.onRemove(0, oldParent, 0);
    expect(currentParent.replies, hasLength(2));
    controller.onRemove(0, currentParent, 1);
    expect(currentParent.replies.single.id.toInt(), 3);
    controller.onRemove(0, currentParent, null);
    expect(list.map((item) => item.id.toInt()), [1, 4]);
    expect(controller.count.value, -1);
    controller.count.value = 0;
    controller.onRemove(99, pinned, null);
    expect(controller.count.value, 0);
    expect(controller.hasUpTop, isFalse);
  });

  test('评论无回显时重查，换凭据淘汰旧查询并释放订阅', () async {
    final controller = _Replies()..onInit();
    addTearDown(controller.onDelete.call);
    controller.savedReplies['draft'] = null;
    controller.onReplyPublished(null);
    expect(controller.requests, hasLength(1));
    Accounts.replaceCredentials(account('new'));
    expect(controller.requests, hasLength(2));
    expect(controller.savedReplies, isEmpty);
    controller.requests.first.complete(
      Success(MainListReply(replies: [reply(9)])),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.loadingState.value, isA<Loading>());
    controller.requests.last.complete(
      Success(MainListReply(replies: [reply(10)])),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.loadingState.value.dataOrNull!.single.id.toInt(), 10);
    controller.onDelete();
    Accounts.replaceCredentials(account('closed'));
    expect(controller.requests, hasLength(2));
  });

  test('楼中楼按当前父项位置插入，刷新和凭据更换更新根评论', () async {
    final controller = _NestedReplies()..onInit();
    addTearDown(controller.onDelete.call);
    final root = reply(2)..count = Int64(2);
    root.replies.addAll([reply(4), reply(3)]);
    controller.requests.first.complete(
      Success(DetailListReply(root: root)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.firstFloor.value, same(root));
    controller.count.value = -1;
    controller
      ..onReplyPublished(reply(5), parent: reply(3))
      ..onReplyPublished(reply(5), parent: reply(3));
    expect(
      controller.loadingState.value.dataOrNull!.map((item) => item.id.toInt()),
      [4, 3, 5],
    );
    expect(controller.count.value, -1);
    controller.onReplyPublished(reply(6), parent: root);
    expect(controller.loadingState.value.dataOrNull!.first.id.toInt(), 6);
    Accounts.replaceCredentials(account('new'));
    expect(controller.firstFloor.value, isNull);
    final nextRoot = reply(2)..ensureContent().message = '新根评论';
    controller.requests.last.complete(Success(DetailListReply(root: nextRoot)));
    await Future<void>.delayed(Duration.zero);
    expect(controller.firstFloor.value, same(nextRoot));
  });
}

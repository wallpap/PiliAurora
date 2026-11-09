import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, ReplyInfo;
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/music/controller.dart';
import 'package:pili_aurora/pages/match_info/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Music extends MusicDetailController {
  _Music() : super(musicId: 'track');
  int commentRequests = 0;
  Object? commentFailure;
  @override
  Future<void> queryData([bool isRefresh = true]) async {
    commentRequests++;
    if (commentFailure case final failure?) throw failure;
  }
}

class _Match extends MatchInfoController {
  _Match({super.oid = 1});
  int commentRequests = 0;
  Completer<void>? commentGate;
  @override
  Future<void> queryData([bool isRefresh = true]) async {
    commentRequests++;
    final gate = commentGate;
    if (gate != null) await gate.future;
  }
}

class _MusicReplies extends MusicDetailController {
  _MusicReplies() : super(musicId: 'track');
  final replies = Completer<LoadingState<MainListReply>>();

  @override
  Future<LoadingState<MainListReply>> customGetData() => replies.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'synthetic-csrf'}),
    null,
    null,
  );
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = account;
    requests.clear();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Map<String, dynamic> music({
    String title = 'sample',
    int? oid,
    int? wishes = 2,
    bool liked = false,
  }) => {
    'code': 0,
    'data': {
      'music_title': title,
      'wish_count': wishes,
      'wish_listen': liked,
      if (oid != null)
        'music_comment': {'oid': oid, 'page_type': 47, 'nums': 3},
    },
  };
  Future<void> load(
    MusicDetailController controller,
    Map<String, dynamic> body,
  ) async {
    final next = requests.length + 1;
    final pending = controller.getMusicDetail();
    await interceptor.waitForRequests(next);
    requests.last.reply.complete(body);
    await pending;
  }

  test('音乐详情重复加载可更新评论来源，不再重复初始化 late final', () async {
    final controller = _Music();
    addTearDown(controller.onDelete.call);
    await load(controller, music(oid: 1));
    await load(controller, music(oid: 2));
    expect(controller.oid, 2);
    expect(controller.replyType, 47);
    expect(controller.commentRequests, 2);
    expect(controller.count.value, 3);
  });

  test('没有评论元数据时详情可用，评论呈现空状态而非持续加载', () async {
    final controller = _Music();
    addTearDown(controller.onDelete.call);
    await load(controller, music());
    expect(controller.infoState.value, isA<Success>());
    expect(controller.canComment, isFalse);
    expect(controller.commentRequests, 0);
    expect(controller.loadingState.value.data, isEmpty);
    expect(controller.emptyReplyMessage, contains('不支持评论'));
    expect(controller.isEnd, isTrue);
  });

  test('刷新为无评论详情后，旧评论的迟到响应不能覆盖空状态', () async {
    final controller = _MusicReplies();
    addTearDown(controller.onDelete.call);
    final old = controller.getMusicDetail();
    await interceptor.waitForRequests(1);
    requests[0].reply.complete(music(oid: 1));
    await Future<void>.delayed(Duration.zero);
    expect(controller.isLoading, isTrue);
    await load(controller, music(title: 'latest'));
    controller.replies.complete(Success(MainListReply(replies: [ReplyInfo()])));
    await old;
    expect(controller.infoState.value.data.musicTitle, 'latest');
    expect(controller.loadingState.value.data, isEmpty);
    expect(controller.count.value, 0);
    expect(controller.isEnd, isTrue);
  });

  test('旧音乐详情不能覆盖新查询或重新发起旧评论查询', () async {
    final controller = _Music();
    addTearDown(controller.onDelete.call);
    final old = controller.getMusicDetail();
    await interceptor.waitForRequests(1);
    final latest = controller.getMusicDetail();
    await interceptor.waitForRequests(2);
    requests[1].reply.complete(music(title: 'latest', oid: 2));
    await latest;
    requests[0].reply.complete(music(title: 'old', oid: 1));
    await old;
    expect(controller.infoState.value.data.musicTitle, 'latest');
    expect(controller.oid, 2);
    expect(controller.commentRequests, 1);
  });

  test('关闭或切号后音乐迟到结果不再发布，也不让页面一直等待', () async {
    final closed = _Music();
    addTearDown(closed.onDelete.call);
    final pending = closed.getMusicDetail();
    await interceptor.waitForRequests(1);
    closed.onDelete();
    requests[0].reply.complete(music(oid: 1));
    await pending;
    expect(closed.infoState.value, isA<Loading>());
    expect(closed.commentRequests, 0);
    final changed = _Music();
    addTearDown(changed.onDelete.call);
    final next = changed.getMusicDetail();
    await interceptor.waitForRequests(2);
    Accounts.accountMode[AccountType.main.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '2'}),
      null,
      null,
    );
    requests[1].reply.complete(music(oid: 1));
    await next;
    expect(changed.infoState.value, isA<Error>());
    expect(changed.infoState.value.toString(), contains('账号已切换'));
    expect(changed.commentRequests, 0);
  });

  test('评论消费失败保留原因，音乐详情仍可展示', () async {
    final cause = StateError('synthetic comment failure');
    final controller = _Music()..commentFailure = cause;
    addTearDown(controller.onDelete.call);
    await load(controller, music(oid: 1));
    expect(controller.infoState.value, isA<Success>());
    expect((controller.loadingState.value as Error).cause, same(cause));
  });

  test('点赞等待服务端确认并拒绝重复提交，未知计数保持未知', () async {
    final controller = _Music();
    addTearDown(controller.onDelete.call);
    await load(controller, music(wishes: null));
    final item = controller.infoState.value.data;
    final liking = controller.toggleWish(item);
    await interceptor.waitForRequests(2);
    await controller.toggleWish(item);
    expect(requests, hasLength(2));
    expect(item.wishListen, isFalse);
    expect(requests[1].options.extra['account'], same(account));
    requests[1].reply.complete({'code': 0});
    await liking;
    expect(item.wishListen, isTrue);
    expect(item.wishCount, isNull);
  });

  test('切号后点赞迟到成功不修改旧详情快照', () async {
    final controller = _Music();
    addTearDown(controller.onDelete.call);
    await load(controller, music());
    final item = controller.infoState.value.data;
    final liking = controller.toggleWish(item);
    await interceptor.waitForRequests(2);
    Accounts.accountMode[AccountType.main.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '2'}),
      null,
      null,
    );
    requests[1].reply.complete({'code': 0});
    await liking;
    expect(item.wishListen, isFalse);
    expect(item.wishCount, 2);
  });

  test('赛事详情和评论独立加载，缺少赛事对象仍是正常成功', () async {
    final gate = Completer<void>();
    final controller = _Match()..commentGate = gate;
    addTearDown(controller.onDelete.call);
    var completed = false;
    final pending = controller.getMatchInfo()
      ..then<void>((_) {
        completed = true;
      });
    await interceptor.waitForRequests(1);
    expect(controller.commentRequests, 1);
    requests[0].reply.complete({'code': 0, 'data': <String, dynamic>{}});
    await Future<void>.delayed(Duration.zero);
    expect(controller.infoState.value.data, isNull);
    expect(completed, isFalse);
    gate.complete();
    await pending;
    expect(completed, isTrue);
  });

  test('赛事详情失败不阻塞评论，非法路由标识不发出任何请求', () async {
    final controller = _Match();
    addTearDown(controller.onDelete.call);
    final pending = controller.getMatchInfo();
    await interceptor.waitForRequests(1);
    requests[0].reply.complete({'code': -403, 'message': '详情拒绝'});
    await pending;
    expect((controller.infoState.value as Error).code, -403);
    expect(controller.commentRequests, 1);
    final invalid = _Match(oid: 0);
    addTearDown(invalid.onDelete.call);
    await invalid.getMatchInfo();
    expect(requests, hasLength(1));
    expect(invalid.infoState.value, isA<Error>());
    expect(invalid.commentRequests, 0);
  });

  test('旧赛事请求与关闭后的结果不更新当前详情', () async {
    final controller = _Match();
    addTearDown(controller.onDelete.call);
    final old = controller.getMatchInfo();
    await interceptor.waitForRequests(1);
    final latest = controller.getMatchInfo();
    await interceptor.waitForRequests(2);
    requests[1].reply.complete({
      'code': 0,
      'data': {
        'contest': {'game_stage': 'latest'},
      },
    });
    await latest;
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'contest': {'game_stage': 'old'},
      },
    });
    await old;
    expect(controller.infoState.value.data!.gameStage, 'latest');
  });
}

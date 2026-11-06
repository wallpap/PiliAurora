import 'dart:collection';
import 'dart:typed_data';

import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/pages/video/reply/controller.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

ReplyInfo _reply(int id) => ReplyInfo(id: Int64(id));

class _TestVideoReplyController extends VideoReplyController {
  _TestVideoReplyController(Queue<LoadingState<MainListReply>> responses)
    : _responses = responses,
      super(aid: 1, videoType: VideoType.ugc, heroTag: 'reply-test');

  final Queue<LoadingState<MainListReply>> _responses;
  int requests = 0;

  @override
  Future<LoadingState<MainListReply>> customGetData() async {
    requests++;
    return _responses.removeFirst();
  }
}

void main() {
  setUpAll(() async {
    GStorage.setting = await Hive.openBox<dynamic>(
      'reply-level-controller',
      bytes: Uint8List(0),
    );
  });
  setUp(() => GStorage.setting.clear());
  tearDownAll(() => GStorage.setting.close());

  ReplyInfo withLevel(int id, int level, [List<ReplyInfo>? replies]) =>
      ReplyInfo(
        id: Int64(id),
        member: Member(level: Int64(level)),
        replies: replies,
      );

  MainListReply page(List<ReplyInfo> replies, {bool end = false}) =>
      MainListReply(
        replies: replies,
        cursor: CursorReply(isEnd: end),
        subjectControl: SubjectControl(count: Int64(100)),
      );

  test('等级过滤补位保留后续页，置顶和楼中楼预览使用同一规则', () async {
    await GStorage.setting.put(SettingBoxKey.minimumReplyUserLevel, 4);
    final first = page([withLevel(1, 2)])..upTop = withLevel(9, 1);
    final controller = _TestVideoReplyController(
      Queue.of([
        Success(first),
        Success(
          page([
            withLevel(2, 4, [withLevel(3, 0), withLevel(4, 6)]),
          ], end: true),
        ),
      ]),
    );
    addTearDown(controller.onClose);
    await controller.queryData();
    final replies = controller.loadingState.value.dataOrNull!;
    expect(replies.map((r) => r.id.toInt()), [2]);
    expect(replies.single.replies.map((r) => r.id.toInt()), [4]);
    expect(controller.hasUpTop, isFalse);
    expect(controller.requests, 2);
    expect(controller.count.value, 100);
    expect(controller.isEnd, isTrue);
  });

  test('连续过滤最多请求五页，空列表仍可继续加载下一批', () async {
    await GStorage.setting.put(SettingBoxKey.minimumReplyUserLevel, 6);
    final controller = _TestVideoReplyController(
      Queue.of([
        for (var i = 1; i <= 5; i++) Success(page([withLevel(i, 1)])),
        Success(page([withLevel(6, 6)], end: true)),
      ]),
    );
    addTearDown(controller.onClose);
    await controller.queryData();
    expect(controller.requests, 5);
    expect(controller.loadingState.value.dataOrNull, isEmpty);
    expect(controller.isEnd, isFalse);
    expect(controller.canLoadMore, isTrue);
    await controller.onLoadMore();
    expect(controller.requests, 6);
    expect(controller.loadingState.value.dataOrNull!.single.id.toInt(), 6);
  });

  test('关闭过滤保留 Lv0，设置变更在刷新后重新加载', () async {
    final controller = _TestVideoReplyController(
      Queue.of([
        Success(page([withLevel(1, 0)], end: true)),
        Success(page([withLevel(1, 0), withLevel(2, 5)], end: true)),
      ]),
    );
    addTearDown(controller.onClose);
    await controller.queryData();
    expect(controller.loadingState.value.dataOrNull!.single.id.toInt(), 1);
    await GStorage.setting.put(SettingBoxKey.minimumReplyUserLevel, 3);
    await controller.onRefresh();
    expect(controller.loadingState.value.dataOrNull!.single.id.toInt(), 2);
  });

  test(
    'pagination removes replies already shown and repeated in one page',
    () async {
      final controller = _TestVideoReplyController(
        Queue.of([
          Success(
            MainListReply(
              replies: [_reply(1), _reply(2)],
              subjectControl: SubjectControl(count: Int64(4)),
            ),
          ),
          Success(
            MainListReply(
              replies: [_reply(2), _reply(3), _reply(3)],
              subjectControl: SubjectControl(count: Int64(4)),
            ),
          ),
        ]),
      );
      addTearDown(controller.onClose);

      await controller.queryData();
      await controller.queryData(false);

      expect(
        controller.loadingState.value.dataOrNull!.map(
          (reply) => reply.id.toInt(),
        ),
        [1, 2, 3],
      );
    },
  );
}

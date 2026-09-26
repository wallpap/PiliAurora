import 'dart:collection';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

ReplyInfo _reply(int id) => ReplyInfo(id: Int64(id));

class _TestVideoReplyController extends VideoReplyController {
  _TestVideoReplyController(Queue<LoadingState<MainListReply>> responses)
    : _responses = responses,
      super(aid: 1, videoType: VideoType.ugc, heroTag: 'reply-test');

  final Queue<LoadingState<MainListReply>> _responses;

  @override
  Future<LoadingState<MainListReply>> customGetData() async =>
      _responses.removeFirst();
}

void main() {
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

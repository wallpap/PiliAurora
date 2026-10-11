import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/video/reply_reply/controller.dart';

void main() {
  test(
    'closing nested replies clears drafts and prevents later requests',
    () async {
      final controller = VideoReplyReplyController(
        hasRoot: true,
        id: null,
        oid: 1,
        rpid: 2,
        dialog: null,
        replyType: 1,
      );
      controller.savedReplies[3] = [];
      controller.onDelete();
      expect(controller.savedReplies, isEmpty);
      expect(controller.isClosed, isTrue);
      // 关闭后请求应由公共控制器拦截，不进入真实 HTTP 调用。
      await controller.queryData();
      expect(controller.isLoading, isFalse);
    },
  );
}

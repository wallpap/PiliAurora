import 'package:pili_aurora/pages/common/common_whisper_controller.dart';
import 'package:pili_aurora/services/messaging/session_models.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';

typedef MsgFeedTopItem = ({
  bool enabled,
  IconData icon,
  String name,
  String route,
});

class WhisperController extends CommonWhisperController {
  WhisperController({required super.sessions})
    : super(folder: SessionFolder.home) {
    final disableLikeMsg = Pref.disableLikeMsg;
    msgFeedTopItems = [
      const (
        name: '回复我的',
        icon: Icons.message_outlined,
        route: '/replyMe',
        enabled: true,
      ),
      const (
        name: '@我',
        icon: Icons.alternate_email_outlined,
        route: '/atMe',
        enabled: true,
      ),
      (
        name: '收到的赞',
        icon: Icons.favorite_border_outlined,
        route: '/likeMe',
        enabled: !disableLikeMsg,
      ),
      const (
        name: '系统通知',
        icon: Icons.notifications_none_outlined,
        route: '/sysMsg',
        enabled: true,
      ),
    ];
  }

  late final List<MsgFeedTopItem> msgFeedTopItems;
}

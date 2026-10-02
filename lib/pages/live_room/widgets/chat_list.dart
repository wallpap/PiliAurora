import 'package:pili_aurora/common/widgets/scroll_physics.dart'
    show platformClampingPhysics;
import 'package:pili_aurora/pages/live_room/chat_buffer.dart';
import 'package:material_ui/material_ui.dart';

class LiveChatList<T> extends StatelessWidget {
  const LiveChatList({
    super.key,
    required this.messages,
    required this.controller,
    required this.itemBuilder,
    required this.historyTruncated,
    required this.maxHistory,
  });

  final List<LiveChatMessage<T>> messages;
  final ScrollController controller;
  final Widget Function(BuildContext, T) itemBuilder;
  final bool historyTruncated;
  final int maxHistory;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      key: const PageStorageKey(LiveChatList),
      // 最新消息在 offset=0，淘汰最早历史不会改变底部的位置。
      reverse: true,
      padding: const .symmetric(horizontal: 12),
      controller: controller,
      physics: platformClampingPhysics,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemCount: messages.length + (historyTruncated ? 1 : 0),
      findItemIndexCallback: (key) {
        if (key is! ValueKey<int>) return null;
        final index = messages.indexWhere((message) => message.id == key.value);
        return index < 0 ? null : messages.length - index - 1;
      },
      itemBuilder: (context, index) {
        if (index == messages.length) {
          return Padding(
            padding: const .symmetric(vertical: 8),
            child: Text(
              '较早消息已移除，最多保留 $maxHistory 条历史',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          );
        }
        final message = messages[messages.length - index - 1];
        return KeyedSubtree(
          key: ValueKey(message.id),
          child: itemBuilder(context, message.content),
        );
      },
    );
  }
}

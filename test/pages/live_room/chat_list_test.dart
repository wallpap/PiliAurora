import 'package:pili_aurora/pages/live_room/chat_buffer.dart';
import 'package:pili_aurora/pages/live_room/widgets/chat_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _panel(
  LiveChatBuffer<int> buffer,
  ScrollController controller, {
  Key? key,
}) => LiveChatList<int>(
  key: key,
  messages: buffer.history,
  controller: controller,
  historyTruncated: buffer.historyTruncated,
  maxHistory: buffer.maxHistory,
  itemBuilder: (_, value) => SizedBox(
    height: value.isEven ? 36 : 64,
    child: Text('消息 $value'),
  ),
);

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(width: 360, height: 300, child: child)),
  ),
);

void main() {
  testWidgets('newest message stays at the bottom through history eviction', (
    tester,
  ) async {
    final buffer = LiveChatBuffer<int>(maxHistory: 20);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    for (var i = 0; i < 20; i++) {
      buffer.add(i);
    }
    await tester.pumpWidget(_app(_panel(buffer, controller)));
    final bottom = tester.getBottomLeft(find.text('消息 19')).dy;
    for (var i = 20; i < 60; i++) {
      buffer.add(i);
      await tester.pumpWidget(_app(_panel(buffer, controller)));
      expect(controller.offset, 0);
      expect(tester.getBottomLeft(find.text('消息 $i')).dy, bottom);
      expect(tester.takeException(), isNull);
    }
    expect(find.text('消息 19'), findsNothing);
  });

  testWidgets('冻结历史在积压、布局迁移与隐藏恢复后保持阅读锚点，恢复跟随时显示最新消息', (tester) async {
    final buffer = LiveChatBuffer<int>();
    final controller = ScrollController();
    final key = GlobalKey();
    addTearDown(controller.dispose);
    for (var i = 0; i < 500; i++) {
      buffer.add(i);
    }
    Widget layout({bool column = false}) {
      final panel = Expanded(child: _panel(buffer, controller, key: key));
      return _app(column ? Column(children: [panel]) : Row(children: [panel]));
    }

    await tester.pumpWidget(layout());
    await tester.drag(find.byType(ListView), const Offset(0, 240));
    await tester.pumpAndSettle();
    buffer.pause();
    final offset = controller.offset;
    final anchor = find.text('消息 491');
    final position = tester.getTopLeft(anchor);
    for (var i = 500; i < 2500; i++) {
      buffer.add(i);
    }
    expect(buffer.historyCount + buffer.pendingCount, 1000);

    for (final column in [false, true]) {
      await tester.pumpWidget(layout(column: column));
      expect(controller.offset, offset);
      expect(tester.getTopLeft(anchor), position);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(_app(const SizedBox.shrink()));
    await tester.pumpWidget(layout(column: true));
    expect(controller.offset, offset);
    expect(tester.getTopLeft(anchor), position);

    buffer.resume();
    controller.jumpTo(0);
    await tester.pumpWidget(layout(column: true));
    expect(find.text('消息 2499'), findsOneWidget);
    expect(controller.offset, 0);
    expect(tester.takeException(), isNull);
  });
}

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
    for (var i = 20; i < 120; i++) {
      buffer.add(i);
      await tester.pumpWidget(_app(_panel(buffer, controller)));
      expect(controller.offset, 0);
      expect(tester.getBottomLeft(find.text('消息 $i')).dy, bottom);
      expect(tester.takeException(), isNull);
    }
    expect(find.text('消息 19'), findsNothing);
  });

  testWidgets('busy unread backlog does not move the message being read', (
    tester,
  ) async {
    final buffer = LiveChatBuffer<int>();
    final controller = ScrollController();
    addTearDown(controller.dispose);
    for (var i = 0; i < 500; i++) {
      buffer.add(i);
    }
    await tester.pumpWidget(_app(_panel(buffer, controller)));
    await tester.drag(find.byType(ListView), const Offset(0, 240));
    await tester.pumpAndSettle();
    buffer.pause();
    final offset = controller.offset;
    final anchor = find.text('消息 491');
    expect(anchor, findsOneWidget);
    final position = tester.getTopLeft(anchor);
    for (var i = 500; i < 100500; i++) {
      buffer.add(i);
    }
    await tester.pumpWidget(_app(_panel(buffer, controller)));
    expect(controller.offset, offset);
    expect(tester.getTopLeft(anchor), position);
    expect(buffer.historyCount + buffer.pendingCount, 1000);

    buffer.resume();
    controller.jumpTo(0);
    await tester.pumpWidget(_app(_panel(buffer, controller)));
    expect(find.text('消息 100499'), findsOneWidget);
    expect(controller.offset, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('moving a frozen panel between layouts preserves its anchor', (
    tester,
  ) async {
    final buffer = LiveChatBuffer<int>();
    final controller = ScrollController();
    final key = GlobalKey();
    addTearDown(controller.dispose);
    for (var i = 0; i < 500; i++) {
      buffer.add(i);
    }
    await tester.pumpWidget(
      _app(
        Row(
          children: [Expanded(child: _panel(buffer, controller, key: key))],
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, 240));
    await tester.pumpAndSettle();
    buffer.pause();
    final anchor = find.text('消息 491');
    final position = tester.getTopLeft(anchor);
    final offset = controller.offset;
    for (var i = 500; i < 2500; i++) {
      buffer.add(i);
    }
    await tester.pumpWidget(
      _app(
        Column(
          children: [Expanded(child: _panel(buffer, controller, key: key))],
        ),
      ),
    );
    expect(controller.offset, offset);
    expect(tester.getTopLeft(anchor), position);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a history boundary without inserting it into messages', (
    tester,
  ) async {
    final buffer = LiveChatBuffer<int>(maxHistory: 2)
      ..add(0)
      ..add(1)
      ..add(2);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(_panel(buffer, controller)));
    expect(find.text('较早消息已移除，最多保留 2 条历史'), findsOneWidget);
    expect(buffer.historyCount, 2);
    expect(find.text('消息 0'), findsNothing);
    expect(
      tester.getTopLeft(find.text('消息 1')).dy,
      lessThan(tester.getTopLeft(find.text('消息 2')).dy),
    );
  });

  testWidgets('hiding and restoring a frozen chat keeps its scroll position', (
    tester,
  ) async {
    final buffer = LiveChatBuffer<int>();
    final controller = ScrollController();
    addTearDown(controller.dispose);
    for (var i = 0; i < 500; i++) {
      buffer.add(i);
    }
    await tester.pumpWidget(_app(_panel(buffer, controller)));
    await tester.drag(find.byType(ListView), const Offset(0, 240));
    await tester.pumpAndSettle();
    buffer.pause();
    final offset = controller.offset;
    await tester.pumpWidget(_app(const SizedBox.shrink()));
    for (var i = 500; i < 2500; i++) {
      buffer.add(i);
    }
    await tester.pumpWidget(_app(_panel(buffer, controller)));
    expect(controller.offset, offset);
    expect(find.text('消息 491'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

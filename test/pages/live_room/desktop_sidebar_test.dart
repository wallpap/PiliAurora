import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/live_room/chat_buffer.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/pages/live_room/widgets/desktop_sidebar.dart';
import 'package:pili_aurora/pages/live_room/widgets/live_list_sheet.dart';
import 'package:pili_aurora/utils/theme_utils.dart';

void main() {
  testWidgets('切换榜单后查看全部调用统一入口', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 600,
            child: DesktopLiveSidebar(
              roomId: 1,
              anchorUid: null,
              anchorName: null,
              liveRoomController: _SidebarController(),
              chat: const SizedBox.expand(),
              input: const SizedBox(height: 48),
              onShowRank: () => opened = true,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('大航海'));
    await tester.pump();
    expect(find.text('舰长榜'), findsOneWidget);
    await tester.tap(find.textContaining('房间观众', findRichText: true));
    await tester.pump();
    expect(find.text('在线榜'), findsOneWidget);
    await tester.tap(find.text('查看全部'));
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('浅色应用中的榜单弹层保持深色且关闭后保留直播页面', (tester) async {
    ThemeUtils.darkTheme = ThemeData.dark();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showLiveListSheet(
                context: context,
                title: '房间观众',
                child: const Text('榜单内容'),
              ),
              child: const Text('直播页面'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('直播页面'));
    await tester.pumpAndSettle();
    expect(find.text('榜单内容'), findsOneWidget);
    final contentContext = tester.element(find.text('榜单内容'));
    expect(Theme.of(contentContext).brightness, Brightness.dark);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('榜单内容'), findsNothing);
    expect(find.text('直播页面'), findsOneWidget);
  });
}

class _SidebarController implements LiveRoomController {
  @override
  final onlineCount = RxnString('191');
  @override
  final messages = Rx<List<LiveChatMessage<dynamic>>>([]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/player_loading.dart';

void main() {
  testWidgets('恢复声音时显示加载，失败后保留明确的重试入口', (tester) async {
    var retries = 0;
    Widget host({required bool failed}) => MaterialApp(
      home: Scaffold(
        body: PlayerLoadingIndicator(
          failed: failed,
          message: failed ? '声音恢复失败，点击重试' : '正在恢复声音...',
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpWidget(host(failed: false));
    expect(find.text('正在恢复声音...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('正在恢复声音...'));
    expect(retries, 0);
    await tester.pumpWidget(host(failed: true));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('声音恢复失败，点击重试'));
    expect(retries, 1);
  });
}

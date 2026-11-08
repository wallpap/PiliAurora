import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/setting/models/play_settings.dart'
    show showVolumeDialog;

void main() {
  testWidgets('音量滑杆拖动时即时预览，取消后恢复原音量', (tester) async {
    double? preview;
    final committed = <double>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showVolumeDialog(
                context,
                title: const Text('播放器音量'),
                value: 60,
                onChanging: (value) => preview = value,
                onChanged: committed.add,
              ),
              child: const Text('打开音量'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开音量'));
    await tester.pumpAndSettle();

    final sliderRect = tester.getRect(find.byType(Slider));
    await tester.tapAt(sliderRect.center);
    await tester.pump();

    expect(preview, closeTo(50, 1));

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(preview, 60);
    expect(committed, isEmpty);
  });
}

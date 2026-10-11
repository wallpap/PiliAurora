import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/desktop_volume_control.dart';

void main() {
  testWidgets('音量菜单支持增强音量、静音与外部状态同步', (tester) async {
    final volume = 0.8.obs;
    final muted = false.obs;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopVolumeControl(
            volume: volume,
            muted: muted,
            maxVolume: 2,
            onChanged: (value) {
              volume.value = value;
              muted.value = false;
            },
            onMuteChanged: (value) => muted.value = value,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pumpAndSettle();
    expect(find.text('80%'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.max, 2);
    slider.onChanged!(1.5);
    await tester.pump();
    expect(find.text('150%'), findsOneWidget);
    await tester.tap(find.byTooltip('静音'));
    await tester.pump();
    expect(muted.value, isTrue);
    expect(volume.value, 1.5);
    volume.value = 0.4;
    await tester.pump();
    expect(find.text('40%'), findsOneWidget);
    await tester.tap(find.byTooltip('取消静音'));
    await tester.pump();
    expect(muted.value, isFalse);
    await tester.tapAt(const Offset(700, 500));
    await tester.pumpAndSettle();
  });
}

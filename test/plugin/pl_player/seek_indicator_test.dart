import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/seek_indicator.dart';

void main() {
  testWidgets(
    'seek directions share debounce and cancel submission on unmount',
    (tester) async {
      final submitted = <Duration>[];
      Future<void> mount(bool forward) => tester.pumpWidget(
        MaterialApp(
          home: SeekIndicator(
            key: ValueKey(forward),
            forward: forward,
            duration: const Duration(seconds: 10),
            onSubmitted: submitted.add,
          ),
        ),
      );

      await mount(false);
      expect(find.byIcon(Icons.fast_rewind), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(find.text('快退20秒'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 399));
      expect(submitted, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(submitted, [const Duration(seconds: 20)]);

      await mount(true);
      expect(find.byIcon(Icons.fast_forward), findsOneWidget);
      expect(find.text('快进10秒'), findsOneWidget);
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(find.text('快进20秒'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(submitted, [const Duration(seconds: 20)]);
    },
  );
}

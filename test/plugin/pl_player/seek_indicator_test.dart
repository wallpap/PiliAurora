import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/seek_indicator.dart';

void main() {
  for (final forward in [false, true]) {
    testWidgets(
      'seek $forward accumulates taps and restarts submission delay',
      (
        tester,
      ) async {
        final submitted = <Duration>[];
        await tester.pumpWidget(
          MaterialApp(
            home: SeekIndicator(
              forward: forward,
              duration: const Duration(seconds: 10),
              onSubmitted: submitted.add,
            ),
          ),
        );
        final direction = forward ? '快进' : '快退';
        expect(find.text('${direction}10秒'), findsOneWidget);
        expect(
          find.byIcon(forward ? Icons.fast_forward : Icons.fast_rewind),
          findsOneWidget,
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byType(InkWell));
        await tester.pump();
        expect(find.text('${direction}20秒'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 399));
        expect(submitted, isEmpty);
        await tester.pump(const Duration(milliseconds: 1));
        expect(submitted, [const Duration(seconds: 20)]);
        await tester.pump(const Duration(seconds: 1));
        expect(submitted, hasLength(1));
      },
    );
  }

  testWidgets('unmount cancels pending seek submission', (tester) async {
    final submitted = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SeekIndicator(
          forward: true,
          duration: const Duration(seconds: 10),
          onSubmitted: submitted.add,
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(submitted, isEmpty);
  });
}

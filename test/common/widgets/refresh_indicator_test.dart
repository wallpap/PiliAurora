import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/refresh_indicator.dart';

void main() {
  Widget indicator(bool refreshing) => MaterialApp(
    home: RefreshIndicator_(isRefreshing: refreshing),
  );

  testWidgets('inactive indicator has no spinner or scheduled frame', (
    tester,
  ) async {
    await tester.pumpWidget(indicator(false));
    await tester.pump(const Duration(seconds: 1));
    final callbacks = tester.binding.transientCallbackCount;
    await tester.pumpWidget(const SizedBox.shrink());
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(callbacks, 0);
  });

  testWidgets('initial refresh is visible and stops after shrinking', (
    tester,
  ) async {
    await tester.pumpWidget(indicator(true));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<ScaleTransition>(find.byType(ScaleTransition)).scale.value,
      1,
    );
    await tester.pumpWidget(indicator(false));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('refresh restarted during shrink keeps its animation', (
    tester,
  ) async {
    await tester.pumpWidget(indicator(false));
    await tester.pumpWidget(indicator(true));
    await tester.pumpWidget(indicator(false));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(indicator(true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/app_menu_theme.dart';
import 'package:pili_aurora/common/widgets/app_popup_menu_item.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('菜单在 $brightness 下保留选中语义、禁用状态与选择回调', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final colors = ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: brightness,
        );
        final taps = <int>[];
        final selections = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorScheme: colors,
              popupMenuTheme: AppMenuTheme.popupMenuThemeData(colors),
            ),
            home: Scaffold(
              body: PopupMenuButton<int>(
                onSelected: selections.add,
                itemBuilder: (_) => [
                  AppPopupMenuItem(
                    value: 0,
                    selected: true,
                    onTap: () => taps.add(0),
                    child: const Text('关闭字幕'),
                  ),
                  AppPopupMenuItem(
                    value: 1,
                    enabled: false,
                    onTap: () => taps.add(1),
                    child: const Text('不可用'),
                  ),
                  AppPopupMenuItem(
                    value: 2,
                    onTap: () => taps.add(2),
                    child: const Text('English'),
                  ),
                ],
                child: const Text('打开菜单'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开菜单'));
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(find.text('关闭字幕')),
          matchesSemantics(
            label: '关闭字幕',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasSelectedState: true,
            isSelected: true,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
          ),
        );
        for (final (label, color) in [
          ('关闭字幕', colors.onSurface),
          ('不可用', colors.onSurface.withValues(alpha: 0.54)),
        ]) {
          expect(
            DefaultTextStyle.of(tester.element(find.text(label))).style.color,
            color,
          );
        }
        await tester.tap(find.text('不可用'));
        await tester.pumpAndSettle();
        expect(taps, isEmpty);
        expect(selections, isEmpty);
        expect(find.text('English'), findsOneWidget);

        await tester.tap(find.text('English'));
        await tester.pumpAndSettle();
        expect(taps, [2]);
        expect(selections, [2]);
        expect(find.text('English'), findsNothing);
      } finally {
        semantics.dispose();
      }
    });
  }
}

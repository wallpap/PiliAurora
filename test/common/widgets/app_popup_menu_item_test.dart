import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/app_menu_theme.dart';
import 'package:pili_aurora/common/widgets/app_popup_menu_item.dart';

void main() {
  testWidgets('操作菜单悬停与点击使用全局内圆角，禁用项保持不可点击', (tester) async {
    final colors = ColorScheme.fromSeed(seedColor: const Color(0xFF5CB67B));
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: colors,
          popupMenuTheme: AppMenuTheme.popupMenuThemeData(colors),
        ),
        home: Scaffold(
          body: PopupMenuButton<int>(
            itemBuilder: (_) => [
              AppPopupMenuItem(
                value: 0,
                onTap: () => taps++,
                child: const Text('消息设置'),
              ),
              AppPopupMenuItem(
                value: 1,
                enabled: false,
                onTap: () => taps++,
                child: const Text('不可用'),
              ),
            ],
            child: const Text('打开菜单'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开菜单'));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('消息设置')));
    await tester.pumpAndSettle();
    final ink = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.text('消息设置'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(ink.borderRadius, BorderRadius.circular(AppMenuTheme.itemRadius));
    final material = tester.widget<Material>(
      find
          .ancestor(
            of: find.text('消息设置'),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.clipBehavior, Clip.antiAlias);
    expect(
      (material.shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(AppMenuTheme.itemRadius),
    );
    await tester.tap(find.text('不可用'));
    await tester.pumpAndSettle();
    expect(taps, 0);
    await tester.tap(find.text('消息设置'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(find.text('消息设置'), findsNothing);
  });

  testWidgets('浮层菜单与内部选项保持同心圆角', (tester) async {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5CB67B),
    );
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: colors,
          popupMenuTheme: AppMenuTheme.popupMenuThemeData(colors),
        ),
        home: Scaffold(
          body: PopupMenuButton<int>(
            onSelected: (value) => selected = value,
            itemBuilder: (_) => const [
              AppPopupMenuItem(
                value: 0,
                selected: true,
                child: Text('关闭字幕'),
              ),
              AppPopupMenuItem(value: 1, child: Text('English')),
            ],
            child: const Text('打开菜单'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开菜单'));
    await tester.pumpAndSettle();

    final roundedMaterials = tester
        .widgetList<Material>(find.byType(Material))
        .where((material) => material.shape is RoundedRectangleBorder)
        .toList();
    final radii = roundedMaterials
        .map(
          (material) =>
              (material.shape! as RoundedRectangleBorder).borderRadius,
        )
        .toList();

    expect(
      radii,
      contains(BorderRadius.circular(AppMenuTheme.menuRadius)),
    );
    expect(
      radii,
      contains(BorderRadius.circular(AppMenuTheme.itemRadius)),
    );
    expect(
      AppMenuTheme.itemRadius,
      AppMenuTheme.menuRadius - AppMenuTheme.menuPadding,
    );
    expect(
      roundedMaterials.any(
        (material) => material.color == AppMenuTheme.selectedBackground(colors),
      ),
      isTrue,
    );

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(selected, 1);
  });
}

import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/pages/setting/widgets/doc_provider_item.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

import '../../support/memory_box.dart';

class _Settings extends MemoryBox {
  _Settings() : super({SettingBoxKey.enableDocProvider: false});

  Completer<void>? saving;
  Object? error;
  int writes = 0;

  @override
  Future<void> put(dynamic key, dynamic value) async {
    writes++;
    await saving?.future;
    if (error case final error?) throw error;
    await super.put(key, value);
  }
}

void main() {
  final settings = _Settings();
  setUpAll(() => GStorage.setting = settings);
  setUp(() {
    settings
      ..saving = null
      ..error = null
      ..writes = 0;
    settings.data[SettingBoxKey.enableDocProvider] = false;
  });

  Future<void> mount(WidgetTester tester, ValueChanged<bool> apply) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [routeObserver],
        builder: FlutterSmartDialog.init(),
        home: Scaffold(body: DocProviderItem(updateProvider: apply)),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
  }

  Switch toggle(WidgetTester tester) =>
      tester.widget<Switch>(find.byType(Switch));

  Future<void> finish(WidgetTester tester) async {
    final dismissal = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissal;
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('DocProvider 原生失败保持确认值，不保存偏好且允许重试', (tester) async {
    var fail = true;
    final calls = <bool>[];
    await mount(tester, (value) {
      calls.add(value);
      if (fail) throw StateError('private-token');
    });
    await tester.tap(find.text(DocProviderItem.title));
    await tester.pumpAndSettle();
    expect(toggle(tester).value, isFalse);
    expect(Pref.enableDocProvider, isFalse);
    expect(settings.writes, 0);
    expect(find.text('设置失败，请重试'), findsOneWidget);
    expect(find.textContaining('private-token'), findsNothing);
    fail = false;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(calls, [true, true]);
    expect(toggle(tester).value, isTrue);
    expect(Pref.enableDocProvider, isTrue);
    await finish(tester);
  });

  testWidgets('DocProvider 保存期间禁止并发，成功后恢复操作', (tester) async {
    settings.saving = Completer<void>();
    final calls = <bool>[];
    await mount(tester, calls.add);
    final change = toggle(tester).onChanged!;
    change(true);
    change(true);
    await tester.pump();
    await tester.tap(find.text(DocProviderItem.title));
    expect(calls, [true]);
    expect(settings.writes, 1);
    expect(toggle(tester).onChanged, isNull);
    settings.saving!.complete();
    await tester.pumpAndSettle();
    expect(toggle(tester).value, isTrue);
    expect(toggle(tester).onChanged, isNotNull);
    expect(Pref.enableDocProvider, isTrue);
    await finish(tester);
  });

  testWidgets('DocProvider 偏好失败恢复原生确认值，重试后共同生效', (tester) async {
    settings.error = StateError('private-storage');
    final calls = <bool>[];
    await mount(tester, calls.add);
    await tester.tap(find.text(DocProviderItem.title));
    await tester.pumpAndSettle();
    expect(calls, [true, false]);
    expect(toggle(tester).value, isFalse);
    expect(Pref.enableDocProvider, isFalse);
    expect(find.text('设置保存失败，请重试'), findsOneWidget);
    expect(find.textContaining('private-storage'), findsNothing);
    settings.error = null;
    await tester.tap(find.text(DocProviderItem.title));
    await tester.pumpAndSettle();
    expect(calls, [true, false, true]);
    expect(toggle(tester).value, isTrue);
    expect(Pref.enableDocProvider, isTrue);
    await finish(tester);
  });

  testWidgets('DocProvider 偏好与原生恢复均失败时，提示待确认并重试同步两端', (tester) async {
    settings.error = StateError('storage');
    final calls = <bool>[];
    await mount(tester, (value) {
      calls.add(value);
      if (!value) throw StateError('rollback');
    });
    await tester.tap(find.text(DocProviderItem.title));
    await tester.pumpAndSettle();
    expect(calls, [true, false]);
    expect(toggle(tester).value, isTrue);
    expect(toggle(tester).onChanged, isNull);
    expect(Pref.enableDocProvider, isFalse);
    expect(find.text('设置未保存，状态待确认，点击重试'), findsWidgets);
    settings.error = null;
    await tester.tap(find.text(DocProviderItem.title));
    await tester.pumpAndSettle();
    expect(calls, [true, false, true]);
    expect(Pref.enableDocProvider, isTrue);
    expect(toggle(tester).onChanged, isNotNull);
    expect(find.text(DocProviderItem.description), findsOneWidget);
    await finish(tester);
  });

  testWidgets('DocProvider 离页再返回仍完成失败恢复，不交付迟到提示', (tester) async {
    settings
      ..saving = Completer<void>()
      ..error = StateError('storage');
    final calls = <bool>[];
    await mount(tester, calls.add);
    await tester.tap(find.text(DocProviderItem.title));
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator))
      ..push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('新页面'))),
      );
    await tester.pumpAndSettle();
    expect(find.text('新页面'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    settings.saving!.complete();
    await tester.pumpAndSettle();
    expect(calls, [true, false]);
    expect(toggle(tester).value, isFalse);
    expect(Pref.enableDocProvider, isFalse);
    expect(find.text('设置保存失败，请重试'), findsNothing);
    await finish(tester);
  });
}

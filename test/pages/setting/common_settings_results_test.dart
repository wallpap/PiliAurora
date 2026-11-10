import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/widgets/switch_item.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/memory_box.dart';

class _Settings extends MemoryBox {
  Completer<void>? saving;
  Object? error;
  final writes = <(dynamic, dynamic)>[];

  @override
  Future<void> put(dynamic key, dynamic value) async {
    writes.add((key, value));
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
      ..error = null;
    settings.data.clear();
    settings.writes.clear();
  });
  tearDown(Get.reset);

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [routeObserver],
        builder: FlutterSmartDialog.init(),
        home: Scaffold(body: child),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
  }

  Future<void> finish(WidgetTester tester) async {
    final dismissal = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissal;
    await tester.pumpWidget(const SizedBox());
  }

  Switch toggle(WidgetTester tester) =>
      tester.widget<Switch>(find.byType(Switch));

  testWidgets('公共开关等待保存回执，失败保持确认值并允许重试', (tester) async {
    settings.saving = Completer<void>();
    final applied = <bool>[];
    await mount(
      tester,
      SetSwitchItem(title: '开关', setKey: 'flag', onChanged: applied.add),
    );
    final change = toggle(tester).onChanged!;
    change(true);
    change(true);
    await tester.pump();
    expect(settings.writes, [('flag', true)]);
    expect(toggle(tester).value, isFalse);
    expect(toggle(tester).onChanged, isNull);
    settings.error = StateError('private-storage');
    settings.saving!.complete();
    await tester.pumpAndSettle();
    expect(toggle(tester).value, isFalse);
    expect(applied, isEmpty);
    expect(find.text('设置保存失败，请重试'), findsOneWidget);
    expect(find.textContaining('private-storage'), findsNothing);
    settings.error = null;
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(toggle(tester).value, isTrue);
    expect(applied, [true]);
    await finish(tester);
  });

  testWidgets('公共开关保存成功后的异步应用失败保留已保存值', (tester) async {
    await mount(
      tester,
      SetSwitchItem(
        title: '开关',
        setKey: 'flag',
        onChanged: (_) => Future<void>.error(StateError('private-apply')),
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(settings.data['flag'], isTrue);
    expect(toggle(tester).value, isTrue);
    expect(find.text('设置已保存，应用失败，请重启后重试'), findsOneWidget);
    expect(find.textContaining('private-apply'), findsNothing);
    await finish(tester);
  });

  testWidgets('公共开关复用时旧回执只应用原设置，不写新来源', (tester) async {
    settings.saving = Completer<void>();
    final key = ValueNotifier('first');
    final first = <bool>[];
    final second = <bool>[];
    await mount(
      tester,
      ValueListenableBuilder(
        valueListenable: key,
        builder: (_, value, _) => SetSwitchItem(
          title: value,
          setKey: value,
          onChanged: value == 'first' ? first.add : second.add,
        ),
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.pump();
    key.value = 'second';
    await tester.pump();
    settings.saving!.complete();
    await tester.pumpAndSettle();
    expect(settings.data['first'], isTrue);
    expect(settings.data['second'], isNull);
    expect(toggle(tester).value, isFalse);
    expect(first, [true]);
    expect(second, isEmpty);
    await finish(tester);
    key.dispose();
  });

  testWidgets('证书开关确认取消保持旧值，确认期间禁止重复弹窗', (tester) async {
    await mount(
      tester,
      const SetSwitchItem(
        title: '证书',
        setKey: SettingBoxKey.badCertificateCallback,
      ),
    );
    final change = toggle(tester).onChanged!;
    change(true);
    change(true);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(settings.writes, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(toggle(tester).value, isFalse);
    expect(settings.writes, isEmpty);
    expect(toggle(tester).onChanged, isNotNull);
    await finish(tester);
  });

  testWidgets('公共开关离页返回后不发布旧保存错误', (tester) async {
    settings.saving = Completer<void>();
    await mount(tester, const SetSwitchItem(title: '开关', setKey: 'flag'));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator))
      ..push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('新页'))),
      );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    settings.error = StateError('storage');
    settings.saving!.complete();
    await tester.pumpAndSettle();
    expect(find.text('设置保存失败，请重试'), findsNothing);
    expect(toggle(tester).value, isFalse);
    await finish(tester);
  });

  testWidgets('屏蔽词校验正则并在保存失败后保留草稿重试', (tester) async {
    settings.data['words'] = '原词';
    final applied = <RegExp>[];
    final model = getBanWordModel(
      title: '屏蔽词',
      key: 'words',
      onChanged: applied.add,
    );
    await mount(tester, model.widget);
    await tester.tap(find.text('屏蔽词'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '[');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入有效的正则表达式'), findsOneWidget);
    expect(settings.writes, isEmpty);
    await tester.enterText(find.byType(TextFormField), '新词|测试');
    settings.error = StateError('private-save');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(
      tester
              .widget<TextFormField>(find.byType(TextFormField))
              .controller
              ?.text ??
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
      '新词|测试',
    );
    expect(settings.data['words'], '原词');
    expect(applied, isEmpty);
    settings.error = null;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(settings.data['words'], '新词|测试');
    expect(applied.single.pattern, '新词|测试');
    expect(find.text('新词|测试'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('屏蔽词保存期间互斥，已保存回调失败单独提示', (tester) async {
    settings.saving = Completer<void>();
    await mount(
      tester,
      getBanWordModel(
        title: '屏蔽词',
        key: 'words',
        onChanged: (_) => throw StateError('apply'),
      ).widget,
    );
    await tester.tap(find.text('屏蔽词'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '词');
    final save = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
        .onPressed!;
    save();
    save();
    await tester.pump();
    expect(settings.writes, [('words', '词')]);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed,
      isNull,
    );
    settings.saving!.complete();
    await tester.pumpAndSettle();
    expect(settings.data['words'], '词');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('设置已保存，应用失败，请重启后重试'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('编辑期间离页返回后拒绝旧草稿保存', (tester) async {
    final applied = <RegExp>[];
    await mount(
      tester,
      getBanWordModel(
        title: '屏蔽词',
        key: 'words',
        onChanged: applied.add,
      ).widget,
    );
    await tester.tap(find.text('屏蔽词'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '旧草稿');
    final navigator = tester.state<NavigatorState>(find.byType(Navigator))
      ..push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('新页'))),
      );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('页面已变化，请重新打开设置'), findsOneWidget);
    expect(settings.writes, isEmpty);
    expect(applied, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('数字预设保存失败保持确认值，不修改传入选项', (tester) async {
    const values = [0, 10];
    final applied = <int>[];
    await mount(
      tester,
      getVideoFilterSelectModel(
        title: '时长',
        key: 'duration',
        values: values,
        onChanged: applied.add,
      ).widget,
    );
    await tester.tap(find.text('时长过滤'));
    await tester.pumpAndSettle();
    settings.error = StateError('storage');
    await tester.tap(find.text('10'));
    await tester.pumpAndSettle();
    expect(find.textContaining('「0」'), findsOneWidget);
    expect(applied, isEmpty);
    expect(find.text('设置保存失败，请重试'), findsOneWidget);
    settings.error = null;
    await tester.tap(find.text('时长过滤'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10'));
    await tester.pumpAndSettle();
    expect(settings.data['duration'], 10);
    expect(applied, [10]);
    expect(values, [0, 10]);
    await finish(tester);
  });

  testWidgets('自定义数字校验输入，保存失败保留输入并重试', (tester) async {
    final applied = <int>[];
    await mount(
      tester,
      getVideoFilterSelectModel(
        title: '时长',
        key: 'duration',
        values: [0, 10],
        onChanged: applied.add,
      ).widget,
    );
    await tester.tap(find.text('时长过滤'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入有效的非负整数'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '25');
    settings.error = StateError('storage');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(applied, isEmpty);
    settings.error = null;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(settings.data['duration'], 25);
    expect(applied, [25]);
    expect(find.byType(AlertDialog), findsNothing);
    await finish(tester);
  });
}

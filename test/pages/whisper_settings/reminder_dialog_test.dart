import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/grpc/bilibili/app/im/v1.pb.dart'
    show IMSettingType, Setting, SettingSelect, SelectItem, GetImSettingsReply;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/setting/widgets/select_dialog.dart';
import 'package:pili_aurora/pages/whisper_settings/controller.dart';
import 'package:pili_aurora/pages/whisper_settings/widgets/reminder_dialog.dart';
import 'package:pili_aurora/services/messaging/settings.dart';

class _Settings extends WhisperSettingsNotifier {
  _Settings(super.type);
  bool disposed = false;
  final saved = <(int, Setting)>[];
  final completion = Completer<LoadingState<void>>();
  final original = Setting(
    select: SettingSelect(
      item: [
        SelectItem(itemType: 1, text: '接收所有提醒', selected: true),
        SelectItem(itemType: 2, text: '不接收提醒'),
      ],
    ),
  );
  @override
  WhisperSettingsSnapshot build() {
    ref.onDispose(() => disposed = true);
    return WhisperSettingsSnapshot(loadingState: LoadingState.loading());
  }

  void ready() => state = WhisperSettingsSnapshot(
    title: '提醒设置',
    loadingState: Success(
      GetImSettingsReply(settings: [MapEntry(7, original)]).settings,
    ),
  );
  @override
  Future<LoadingState<void>> setSetting(int key, Setting setting) {
    saved.add((key, setting));
    return completion.future;
  }
}

class _Harness {
  _Harness(this.type);
  final IMSettingType type;
  late _Settings settings;
  Widget build() => ProviderScope(
    overrides: [
      whisperSettingsProvider(type)
          .overrideWith(() => settings = _Settings(type)),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: MessageReminderButton(
          type: type,
          title: '提醒',
          icon: const Icon(Icons.settings),
        ),
      ),
    ),
  );
}

void main() {
  for (final type in [
    IMSettingType.SETTING_TYPE_OLD_RECEIVE_LIKE,
    IMSettingType.SETTING_TYPE_OLD_REPLY_ME,
    IMSettingType.SETTING_TYPE_OLD_AT_ME,
  ]) {
    testWidgets('$type：结果就绪前不弹窗，选择后保存并释放订阅', (tester) async {
      final harness = _Harness(type);
      await tester.pumpWidget(harness.build());
      await tester.tap(find.byType(IconButton));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        Navigator.of(tester.element(find.byType(MessageReminderButton)))
            .canPop(),
        isFalse,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
      harness.settings.ready();
      await tester.pumpAndSettle();
      expect(find.byType(SelectDialog<int>), findsOneWidget);
      expect(find.text('接收所有提醒'), findsOneWidget);
      expect(find.text('不接收提醒'), findsOneWidget);
      await tester.tap(find.text('不接收提醒'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(harness.settings.saved.single.$1, 7);
      expect(
        harness.settings.saved.single.$2.select.item.map((e) => e.selected),
        [false, true],
      );
      expect(harness.settings.original.select.item.first.selected, isTrue);
      expect(harness.settings.disposed, isFalse);
      harness.settings.completion.complete(const Success(null));
      await tester.pumpAndSettle();
      expect(harness.settings.disposed, isTrue);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('取消选择不写入设置并释放订阅', (tester) async {
    final harness = _Harness(IMSettingType.SETTING_TYPE_OLD_RECEIVE_LIKE);
    await tester.pumpWidget(harness.build());
    await tester.tap(find.byType(IconButton));
    harness.settings.ready();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(harness.settings.saved, isEmpty);
    expect(harness.settings.disposed, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });
  testWidgets('读取期间返回上一页会释放订阅', (tester) async {
    const type = IMSettingType.SETTING_TYPE_OLD_RECEIVE_LIKE;
    final harness = _Harness(type);
    await tester.pumpWidget(harness.build());
    final navigator =
        Navigator.of(
          tester.element(find.byType(MessageReminderButton)),
        )..push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(
              body: MessageReminderButton(
                type: type,
                title: '提醒',
                icon: Icon(Icons.settings),
              ),
            ),
          ),
        );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(IconButton));
    navigator.pop();
    await tester.pumpAndSettle();
    expect(harness.settings.disposed, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

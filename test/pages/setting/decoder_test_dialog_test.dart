import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/pages/setting/widgets/decoder_test_dialog.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/utils/storage.dart';

Future<void> _open(
  WidgetTester tester,
  Future<List<VideoItem>> Function() loader,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => DecoderTestDialog(sampleLoader: loader),
            ),
            child: const Text('打开测试'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开测试'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

List<VideoItem> _samples() => [
  for (final codec in [7, 13])
    VideoItem(
      id: 80,
      codecid: codec,
      baseUrl: 'https://example.test/sample-$codec.mp4',
      quality: VideoQuality.high1080,
    ),
];

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pili-decoder-dialog-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('decoder media requests use the same headers as normal playback', () {
    String? capturedUserAgent;
    String? capturedReferer;
    configureDecoderTestMediaHeaders(({String? userAgent, String? referer}) {
      capturedUserAgent = userAgent;
      capturedReferer = referer;
    });

    expect(capturedUserAgent, BrowserUa.pc);
    expect(capturedReferer, HttpString.baseUrl);
  });

  testWidgets('decoder dialog opens within the app Material UI context', (
    tester,
  ) async {
    await _open(tester, () async => []);
    expect(tester.takeException(), isNull);
    expect(find.text('解码器测试'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('解码器测试'), findsNothing);
  });

  testWidgets(
    'sample timeout shows retry and a successful retry enables selections',
    (tester) async {
      final stalled = Completer<List<VideoItem>>();
      var calls = 0;
      await _open(
        tester,
        () => calls++ == 0 ? stalled.future : Future.value(_samples()),
      );
      expect(find.text('正在获取测试视频…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(find.text('无法获取测试视频，请检查网络后重试'), findsOneWidget);
      await tester.tap(find.text('重新获取'));
      await tester.pumpAndSettle();
      expect(find.text('AVC'), findsOneWidget);
      expect(find.text('AV1'), findsOneWidget);
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'AV1'))
            .selected,
        isFalse,
      );
      await tester.tap(find.text('AV1'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'AV1'))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始测试选中项'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      stalled.complete([]);
      await tester.pump();
    },
  );

  testWidgets('closing while loading ignores the late sample response', (
    tester,
  ) async {
    final loading = Completer<List<VideoItem>>();
    await _open(tester, () => loading.future);
    expect(find.text('正在获取测试视频…'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    loading.complete(_samples());
    await tester.pump();
    expect(find.text('解码器测试'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

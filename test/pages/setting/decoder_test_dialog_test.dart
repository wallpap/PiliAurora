import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/pages/setting/widgets/decoder_test_dialog.dart';
import 'package:pili_aurora/pages/setting/decoder_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

Future<void> _open(
  WidgetTester tester,
  Future<List<VideoItem>> Function() loader, {
  DecoderTestSessionFactory? sessionFactory,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => DecoderTestDialog(
                sampleLoader: loader,
                sessionFactory: sessionFactory,
              ),
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
  setUpAll(() => GStorage.setting = MemoryBox<dynamic>());

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
      await tester.tap(find.widgetWithText(FilterChip, 'AVC'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始测试选中项'))
            .onPressed,
        isNull,
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

  testWidgets('资源释放中停止测试，完成释放前不能重新开始', (tester) async {
    final sessions = <_Session>[];
    await _open(
      tester,
      () async => _samples(),
      sessionFactory: (_, _) {
        final session = _Session();
        sessions.add(session);
        return session;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始测试选中项'));
    await tester.pump();
    expect(sessions, hasLength(1));
    sessions.first.result.complete(_success('first'));
    await tester.pump();
    expect(sessions.first.disposeCalls, 1);
    await tester.tap(find.text('停止测试'));
    await tester.pump();
    expect(find.text('正在停止…'), findsOneWidget);
    expect(sessions, hasLength(1));
    sessions.first.released.complete();
    await tester.pumpAndSettle();
    expect(find.text('开始测试选中项'), findsOneWidget);
    expect(sessions, hasLength(1));
  });

  testWidgets('停止后迟到的旧结果不得覆盖新测试或释放新会话', (tester) async {
    final sessions = <_Session>[];
    await _open(
      tester,
      () async => _samples(),
      sessionFactory: (_, _) {
        final session = _Session();
        sessions.add(session);
        return session;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始测试选中项'));
    await tester.pump();
    await tester.tap(find.text('停止测试'));
    await tester.pump();
    sessions.first.released.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始测试选中项'));
    await tester.pump();
    expect(sessions, hasLength(2));
    sessions.first.result.complete(_success('obsolete-backend'));
    await tester.pump();
    expect(find.textContaining('obsolete-backend'), findsNothing);
    expect(sessions.last.disposeCalls, 0);
    await tester.tap(find.text('停止测试'));
    await tester.pump();
    expect(sessions.last.disposeCalls, 1);
    sessions.last.released.complete();
    sessions.last.result.complete(const DecoderTestResult.cancelled());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭正在初始化的测试后释放会话并忽略迟到结果', (tester) async {
    final session = _Session();
    await _open(
      tester,
      () async => _samples(),
      sessionFactory: (_, _) => session,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始测试选中项'));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(session.disposeCalls, 1);
    session.released.complete();
    session.result.complete(_success('late-result'));
    await tester.pumpAndSettle();
    expect(find.text('解码器测试'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

DecoderTestResult _success(String name) => DecoderTestResult.success(
  decoder: name,
  size: '1920x1080',
  speed: 1,
  fallback: false,
  performance: const DecoderPerformance(),
);

class _Session implements DecoderTestSession {
  @override
  final videoController = ValueNotifier<VideoController?>(null);
  final result = Completer<DecoderTestResult>();
  final released = Completer<void>();
  int disposeCalls = 0;
  Future<void>? _disposing;
  @override
  Future<DecoderTestResult> run() => result.future;
  @override
  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    disposeCalls++;
    await released.future;
  }
}

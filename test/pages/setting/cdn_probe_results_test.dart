import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/video/cdn_type.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/pages/setting/widgets/select_dialog.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_http_adapter.dart';
import '../../support/memory_box.dart';

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  final deadline = tester.binding.clock.now().add(const Duration(seconds: 3));
  while (!condition() && tester.binding.clock.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}

void _check(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ControlledHttpAdapter adapter;
  late Dio dio;
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.video = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>({
      LocalCacheKey.mixinKey: 'fixture',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
  });
  setUp(() {
    adapter = ControlledHttpAdapter();
    dio = Dio()..httpClientAdapter = adapter;
  });
  final sample = VideoItem(
    id: 80,
    quality: VideoQuality.high1080,
    baseUrl: 'https://upos-sz-mirrorali.bilivideo.com/a?token=secret',
  );
  Future<void> host(WidgetTester tester, {BaseItem? value}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CdnSelectDialog(sample: value, client: dio),
      ),
    );
  }

  _check('short successful sample produces a speed and continues probes', (
    tester,
  ) async {
    await host(tester, value: sample);
    await tester.pump();
    await _until(tester, () => adapter.requests.isNotEmpty);
    adapter.pending[0].complete(ResponseBody.fromBytes([1, 2, 3], 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.textContaining('MB/s'), findsOneWidget);
    expect(adapter.requests.length, 2);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  _check('probe exception does not display signed URL details', (
    tester,
  ) async {
    await host(tester, value: sample);
    await tester.pump();
    await _until(tester, () => adapter.requests.isNotEmpty);
    adapter.pending[0].completeError(
      DioException(
        requestOptions: adapter.requests[0],
        error: 'https://private?token=secret',
        type: DioExceptionType.connectionError,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.text('测速失败，请重试'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  _check(
    'empty source gives explicit failures without starting requests',
    (tester) async {
      await host(
        tester,
        value: VideoItem(id: 80, quality: VideoQuality.high1080),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.text('测速失败，请重试'), findsNWidgets(CDNService.values.length));
      expect(adapter.requests, isEmpty);
    },
  );

  _check('empty sampling response ends all waiting indicators', (
    tester,
  ) async {
    Request();
    Request.dio.interceptors.clear();
    final sourceAdapter = ControlledHttpAdapter();
    Request.dio.httpClientAdapter = sourceAdapter;
    await host(tester);
    await tester.pump();
    await _until(tester, () => sourceAdapter.requests.isNotEmpty);
    sourceAdapter.json(0, {
      'code': 0,
      'data': {
        'dash': {'video': []},
      },
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await _until(tester, () => find.text('无法获取测速来源，请重试').evaluate().isNotEmpty);
    expect(find.text('无法获取测速来源，请重试'), findsNWidgets(CDNService.values.length));
    expect(adapter.requests, isEmpty);
    sourceAdapter.close();
  });
}

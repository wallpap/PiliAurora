import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/article/controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_http_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ControlledHttpAdapter adapter;
  setUpAll(() async {
    GStorage.setting = await Hive.openBox(
      'audit3-settings',
      bytes: Uint8List(0),
    );
    GStorage.video = await Hive.openBox('audit3-video', bytes: Uint8List(0));
    GStorage.localCache = await Hive.openBox(
      'audit3-cache',
      bytes: Uint8List(0),
    );
    await GStorage.localCache.put(LocalCacheKey.mixinKey, 'synthetic');
    await GStorage.localCache.put(
      LocalCacheKey.timeStamp,
      DateTime.now().millisecondsSinceEpoch,
    );
    Request();
    Request.dio.interceptors.clear();
  });
  setUp(() {
    adapter = ControlledHttpAdapter();
    Request.dio.httpClientAdapter = adapter;
  });
  tearDown(() => adapter.close());
  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
  });
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  Future<void> mount(WidgetTester tester, [Widget? child]) => tester.pumpWidget(
    MaterialApp(
      builder: FlutterSmartDialog.init(),
      home: child ?? const SizedBox(),
    ),
  );

  testWidgets('article content failure can be retried', (tester) async {
    await mount(tester);
    final controller = ArticleController()
      ..type = 'opus'
      ..id = '1';
    addTearDown(controller.onClose);
    controller.init();
    await flush(tester);
    expect(adapter.pending, hasLength(1));
    adapter.json(0, {'code': -1, 'message': 'synthetic temporary error'});
    await flush(tester);
    expect(controller.loadingState.value, isA<Error>());
    final retry = controller.onReload();
    await flush(tester);
    expect(adapter.pending, hasLength(2));
    adapter.json(1, {'code': -1, 'message': 'synthetic'});
    await flush(tester);
    await retry;
  });
  testWidgets('opus 回退文章后仍请求正文并允许重试', (tester) async {
    await mount(tester);
    final controller = ArticleController()
      ..type = 'opus'
      ..id = '1';
    addTearDown(controller.onClose);
    controller.init();
    await flush(tester);
    adapter.json(0, {
      'code': 0,
      'data': {
        'fallback': {'id': '2'},
      },
    });
    await flush(tester);
    expect(adapter.pending, hasLength(2));
    adapter.json(1, {'code': -1, 'message': 'temporary'});
    await flush(tester);
    expect(controller.type, 'read');
    final retry = controller.onReload();
    await flush(tester);
    expect(adapter.pending, hasLength(3));
    adapter.json(2, {'code': -1, 'message': 'temporary'});
    await flush(tester);
    await retry;
    expect(controller.isLoaded.value, isFalse);
  });
}

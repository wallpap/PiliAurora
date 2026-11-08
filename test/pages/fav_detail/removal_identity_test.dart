import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/fav/fav_detail/media.dart';
import 'package:pili_aurora/pages/fav_detail/controller.dart';
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

  testWidgets('concurrent unfavorites remove their identities', (
    tester,
  ) async {
    await mount(tester);
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    final controller = FavDetailController()..mediaId = 7;
    addTearDown(controller.onClose);
    controller.folderInfo.value.mediaCount = 3;
    controller.loadingState.value = Success([
      for (var id = 1; id <= 3; id++) FavDetailItemModel(id: id, type: 2),
    ]);
    final first = controller.onCancelFav(0, 1, 2);
    final second = controller.onCancelFav(1, 2, 2);
    await flush(tester);
    expect(adapter.pending, hasLength(2));
    adapter.json(0, {'code': 0});
    await flush(tester);
    await first;
    adapter.json(1, {'code': 0});
    await flush(tester);
    await second;
    expect(controller.loadingState.value.data!.map((e) => e.id), [3]);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
  testWidgets('刷新中的收藏列表拒绝迟到删除结果', (tester) async {
    await mount(tester);
    final controller = FavDetailController()..mediaId = 7;
    addTearDown(controller.onClose);
    controller.loadingState.value = Success([
      FavDetailItemModel(id: 1, type: 2),
    ]);
    final remove = controller.onCancelFav(0, 1, 2);
    await flush(tester);
    controller.loadingState.value = LoadingState.loading();
    adapter.json(0, {'code': 0});
    await flush(tester);
    await remove;
    expect(controller.loadingState.value, isA<Loading>());
  });
}

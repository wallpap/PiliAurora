import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Video extends VideoDetailController {
  bool closed = false;
  @override
  bool get isClosed => closed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final casts = <Map<String, String?>>[];
  late _Video controller;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    requests.clear();
    casts.clear();
    controller = _Video()
      ..cid = 1.obs
      ..aid = 1
      ..bvid = 'BV1xx411c7mD'
      ..heroTag = 'cast-test'
      ..videoType = VideoType.ugc;
  });
  tearDown(() {
    controller.closed = true;
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    GetMaterialApp(
      builder: FlutterSmartDialog.init(),
      navigatorObservers: [routeObserver, FlutterSmartDialog.observer],
      initialRoute: '/',
      getPages: [
        GetPage(
          name: '/',
          page: () => const Scaffold(body: Text('视频页面')),
        ),
        GetPage(
          name: '/other',
          page: () => const Scaffold(body: Text('其他页面')),
        ),
        GetPage(
          name: '/dlna',
          page: () {
            casts.add(Map.of(Get.parameters));
            return const Scaffold(body: Text('投屏页面'));
          },
        ),
      ],
    ),
  );
  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; !ready() && i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(ready(), true);
  }

  Future<void> complete(
    WidgetTester tester,
    Future<void> operation,
    int index,
    Object body,
  ) async {
    var done = false;
    unawaited(operation.whenComplete(() => done = true));
    requests[index].reply.complete(body);
    await until(tester, () => done);
    await operation;
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> finish(WidgetTester tester) async {
    final loading = SmartDialog.dismiss(status: .loading);
    await tester.pumpAndSettle();
    await loading;
    final dialogs = SmartDialog.dismiss(status: .allDialog);
    await tester.pumpAndSettle();
    await dialogs;
    final toasts = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await toasts;
    await tester.pumpWidget(const SizedBox());
  }

  Object media() => {
    'code': 0,
    'data': {
      'durl': [
        {'url': 'https://example.com/cast.mp4'},
      ],
    },
  };

  testWidgets('投屏查询互斥，失败收尾只关闭自身加载并允许重试', (tester) async {
    await mount(tester);
    SmartDialog.showLoading(msg: '其他任务');
    final first = controller.onCast();
    await until(tester, () => requests.length == 1);
    await controller.onCast();
    expect(requests, hasLength(1));
    await complete(tester, first, 0, {'code': -403, 'message': '投屏拒绝'});
    expect(find.text('投屏拒绝'), findsOneWidget);
    expect(
      SmartDialog.checkExist(dialogTypes: {SmartAllDialogType.loading}),
      true,
    );
    final retry = controller.onCast();
    await until(tester, () => requests.length == 2);
    await complete(tester, retry, 1, media());
    expect(casts, hasLength(1));
    expect(casts.single['url'], 'https://example.com/cast.mp4');
    await finish(tester);
  });

  testWidgets('换分P后迟到投屏查询不能打开设备页', (tester) async {
    await mount(tester);
    final pending = controller.onCast();
    await until(tester, () => requests.length == 1);
    controller.cid.value = 2;
    await complete(tester, pending, 0, media());
    expect(casts, isEmpty);
    expect(find.text('视频页面'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('离页后再返回仍丢弃旧投屏错误', (tester) async {
    await mount(tester);
    final pending = controller.onCast();
    await until(tester, () => requests.length == 1);
    Get.toNamed('/other');
    await tester.pumpAndSettle();
    Get.back();
    await tester.pumpAndSettle();
    await complete(tester, pending, 0, {'code': -403, 'message': '迟到投屏错误'});
    expect(find.text('迟到投屏错误'), findsNothing);
    expect(casts, isEmpty);
    await finish(tester);
  });
}

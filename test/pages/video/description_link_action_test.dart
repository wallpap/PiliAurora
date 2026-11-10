import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/description_link_action.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_http_adapter.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ControlledHttpAdapter adapter;
  late UgcDescriptionLinkAction action;
  late BuildContext context;
  late Account originalAccount;
  var sourceCurrent = true;
  final opened = <String>[];
  const url = 'https://youtu.be/abcdefghijk';

  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    GStorage.video = MemoryBox<dynamic>();
    Request();
    Request.dio.interceptors.clear();
  });
  setUp(() async {
    originalAccount = Accounts.main;
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    await GStorage.setting.put(SettingBoxKey.blockServer, 'https://block.test');
    await GStorage.setting.put(SettingBoxKey.blockUserID, 'binding-user');
    sourceCurrent = true;
    opened.clear();
    adapter = ControlledHttpAdapter();
    Request.dio.httpClientAdapter = adapter;
    action = UgcDescriptionLinkAction(
      openLink: (link) async => opened.add(link),
    );
  });
  tearDown(() {
    Accounts.accountMode[AccountType.main.index] = originalAccount;
    adapter.close();
    Get.reset();
  });
  tearDownAll(() => Request.dio.close(force: true));

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    GetMaterialApp(
      navigatorObservers: [routeObserver, FlutterSmartDialog.observer],
      builder: FlutterSmartDialog.init(),
      home: Builder(
        builder: (value) {
          context = value;
          return const Scaffold(body: Text('视频来源'));
        },
      ),
    ),
  );
  Future<void> until(WidgetTester tester, bool Function() ready) async {
    final end = tester.binding.clock.now().add(const Duration(seconds: 3));
    while (!ready() && tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(ready(), isTrue);
  }

  Future<void> finish(WidgetTester tester, Future<void> operation) async {
    var done = false;
    unawaited(operation.then((_) => done = true));
    await until(tester, () => done);
    await operation;
    SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  }

  Future<void> run() => action.run(
    context: context,
    url: url,
    bvid: 'video',
    cid: 42,
    duration: 60000,
    enableSponsorBlock: true,
    isCurrent: () => sourceCurrent,
  );
  void status(int index, int value) => adapter.pending[index].complete(
    ResponseBody.fromString('', value),
  );
  Future<void> confirmQuery(WidgetTester tester, {String? binding}) async {
    await until(tester, () => adapter.requests.isNotEmpty);
    if (binding == null) {
      status(0, 404);
    } else {
      adapter.json(0, {'ytbID': binding});
    }
    await until(tester, () => find.text('确认').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
  }

  testWidgets('404 后确认写入固定目标，成功后才提示，重复点击不并发', (tester) async {
    await mount(tester);
    final operation = run();
    await run();
    await confirmQuery(tester);
    expect(adapter.requests, hasLength(1));
    await tester.tap(find.text('确认'));
    await until(tester, () => adapter.requests.length == 2);
    final write = adapter.requests[1];
    expect(write.method, 'POST');
    expect(write.extra['noRetry'], isTrue);
    expect(write.data, {
      'bvID': 'video',
      'cid': '42',
      'ytbID': 'abcdefghijk',
      'userID': 'binding-user',
      'biliDuration': 60,
    });
    expect(find.text('提交搬运视频成功'), findsNothing);
    adapter.json(1, {'UUID': 'confirmed'});
    await until(tester, () => find.text('提交搬运视频成功').evaluate().isNotEmpty);
    expect(opened, isEmpty);
    await finish(tester, operation);
  });

  for (final alreadyBound in [false, true]) {
    testWidgets('${alreadyBound ? '已有相同绑定' : '取消绑定'}打开原链接且不写入', (tester) async {
      await mount(tester);
      final operation = run();
      await confirmQuery(tester, binding: alreadyBound ? 'abcdefghijk' : null);
      await tester.tap(find.text(alreadyBound ? '确认' : '取消'));
      await until(tester, () => opened.isNotEmpty);
      expect(opened, [url]);
      expect(adapter.requests, hasLength(1));
      await finish(tester, operation);
    });
  }

  testWidgets('查询失败保留现有绑定并打开原链接', (tester) async {
    await mount(tester);
    final operation = run();
    await until(tester, () => adapter.requests.isNotEmpty);
    status(0, 500);
    await until(tester, () => opened.isNotEmpty);
    expect(find.text('确认'), findsNothing);
    expect(adapter.requests, hasLength(1));
    await finish(tester, operation);
  });

  for (final change in ['账号', '来源', '绑定身份', '服务器']) {
    testWidgets('确认期间$change改变后不写入或打开旧链接', (tester) async {
      await mount(tester);
      final operation = run();
      await confirmQuery(tester);
      switch (change) {
        case '账号':
          Accounts.accountMode[AccountType.main.index] = LoginAccount(
            BiliCookieJar.fromJson({'DedeUserID': '1'}),
            null,
            null,
          );
        case '来源':
          sourceCurrent = false;
        case '绑定身份':
          await GStorage.setting.put(SettingBoxKey.blockUserID, 'replacement');
        case '服务器':
          await GStorage.setting.put(
            SettingBoxKey.blockServer,
            'https://new.test',
          );
      }
      await tester.tap(find.text('确认'));
      await finish(tester, operation);
      expect(adapter.requests, hasLength(1));
      expect(opened, isEmpty);
    });
  }

  for (final response in [403, 500]) {
    testWidgets('写入 HTTP $response 交付拒绝或待确认，重试先查询绑定', (tester) async {
      await mount(tester);
      final operation = run();
      await confirmQuery(tester);
      await tester.tap(find.text('确认'));
      await until(tester, () => adapter.requests.length == 2);
      status(1, response);
      await until(
        tester,
        () => find
            .text(response == 403 ? '被自动审核机制拒绝' : '操作结果待确认，请先核对后再操作')
            .evaluate()
            .isNotEmpty,
      );
      var done = false;
      unawaited(operation.then((_) => done = true));
      await until(tester, () => done);
      final retry = run();
      await until(tester, () => adapter.requests.length == 3);
      expect(adapter.requests.last.method, 'GET');
      adapter.json(2, {'ytbID': 'abcdefghijk'});
      await until(tester, () => find.text('确认').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await finish(tester, retry);
      expect(adapter.requests, hasLength(3));
    });
  }

  testWidgets('离页返回后查询结果不弹确认', (tester) async {
    await mount(tester);
    final operation = run();
    await until(tester, () => adapter.requests.isNotEmpty);
    Get.key.currentState!.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    Get.key.currentState!.pop();
    await tester.pumpAndSettle();
    status(0, 404);
    await finish(tester, operation);
    expect(find.text('确认'), findsNothing);
    expect(opened, isEmpty);
  });

  testWidgets('写入成功迟到后不提示到替换的来源', (tester) async {
    await mount(tester);
    final operation = run();
    await confirmQuery(tester);
    await tester.tap(find.text('确认'));
    await until(tester, () => adapter.requests.length == 2);
    sourceCurrent = false;
    adapter.json(1, {'UUID': 'confirmed'});
    await finish(tester, operation);
    expect(find.text('提交搬运视频成功'), findsNothing);
    expect(opened, isEmpty);
  });
}

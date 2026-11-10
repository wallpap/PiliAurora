import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/pages/download/controller.dart';
import 'package:pili_aurora/pages/download/deletion.dart';
import 'package:pili_aurora/pages/download/search/controller.dart';
import 'package:pili_aurora/services/download/download_service.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../services/download/download_fixtures.dart';
import '../../support/memory_box.dart';

class _Box extends MemoryBox<int> {
  bool fail = false;
  @override
  Future<void> deleteAll(Iterable<dynamic> keys) async {
    if (fail) throw StateError('private-record');
    for (final key in keys) {
      await delete(key);
    }
  }
}

class _Service extends GetxService implements DownloadService {
  @override
  final downloadList = <BiliDownloadEntryInfo>[];
  @override
  final SetNotifier flagNotifier = {};
  @override
  Future<void> waitForInitialization = Future.value();
  final requests = <BiliDownloadEntryInfo>[];
  final pageRequests = <String>[];
  final replies = <Completer<LoadingState<void>>>[];
  @override
  Future<LoadingState<void>> deletePage({
    required String pageDirPath,
    bool refresh = true,
  }) async {
    pageRequests.add(pageDirPath);
    final reply = Completer<LoadingState<void>>();
    replies.add(reply);
    final result = await reply.future;
    if (result.isSuccess) {
      downloadList.removeWhere((entry) => entry.pageDirPath == pageDirPath);
      for (final listener in flagNotifier.toList()) {
        listener();
      }
    }
    return result;
  }

  @override
  Future<LoadingState<void>> deleteDownload({
    required BiliDownloadEntryInfo entry,
    bool removeList = false,
    bool removeQueue = false,
    bool refresh = true,
    bool downloadNext = true,
  }) {
    requests.add(entry);
    final reply = Completer<LoadingState<void>>();
    replies.add(reply);
    return reply.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final box = _Box();
  late _Service service;
  setUpAll(() => GStorage.watchProgress = box);
  setUp(() {
    box.fail = false;
    service = Get.put<DownloadService>(_Service()) as _Service;
  });
  tearDown(() async {
    await box.clear();
    Get.reset();
  });
  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    GetMaterialApp(
      builder: FlutterSmartDialog.init(),
      home: const Scaffold(),
    ),
  );
  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('搜索删除等待确认，重复调用合并，失败保留选择和播放记录，成功才清理', (tester) async {
    await mount(tester);
    final controller = DownloadSearchController();
    addTearDown(controller.onDelete.call);
    final a = downloadEntry(cid: 1)..checked = true;
    final b = downloadEntry(cid: 2)..checked = true;
    final source = [a, b];
    controller.loadingState.value = Success(source);
    controller.enableMultiSelect.value = true;
    controller.rxCount.value = 2;
    await box.putAll({'1': 10, '2': 20});
    final pending = controller.removeEntries([a, b]);
    await controller.removeEntries([a]);
    expect(service.requests, [a]);
    expect(source, [a, b]);
    service.replies[0].complete(const Error('删除失败，请重试'));
    await tester.pump();
    expect(service.requests, [a, b]);
    service.replies[1].complete(const Success(null));
    await pending;
    expect(source, [a]);
    expect(a.checked, true);
    expect(controller.rxCount.value, 1);
    expect(controller.enableMultiSelect.value, true);
    expect(box.get('1'), 10);
    expect(box.get('2'), isNull);
    await finish(tester);
  });
  testWidgets('搜索刷新后旧删除结果不改新快照，播放记录仍按确认成功清理', (tester) async {
    await mount(tester);
    final controller = DownloadSearchController();
    addTearDown(controller.onDelete.call);
    final a = downloadEntry(cid: 1);
    controller.loadingState.value = Success([a]);
    await box.put('1', 10);
    final pending = controller.onRemoveSingle(0, a);
    final fresh = [downloadEntry(cid: 1)];
    controller.loadingState.value = Success(fresh);
    service.replies.single.complete(const Success(null));
    await pending;
    expect(fresh, hasLength(1));
    expect(box.get('1'), isNull);
    await finish(tester);
  });
  testWidgets('播放记录清理失败保留下载删除成功，不显示异常正文', (tester) async {
    await mount(tester);
    box.fail = true;
    final a = downloadEntry();
    final deleted = <BiliDownloadEntryInfo>[];
    final helper = DownloadDeletion();
    final result = await helper.run(
      items: [a],
      delete: (_) async => const Success<void>(null),
      entries: (item) => [item],
      isCurrent: () => true,
      onDeleted: deleted.add,
    );
    await tester.pumpAndSettle();
    expect(result, {a});
    expect(deleted, [a]);
    expect(helper.busy, false);
    expect(find.text('下载已删除，播放记录清理失败'), findsOneWidget);
    expect(find.textContaining('private-record'), findsNothing);
    await finish(tester);
  });
  testWidgets('页面失效停止后续批量项，迟到成功仍清理自身记录但不回调', (tester) async {
    await mount(tester);
    final a = downloadEntry(cid: 1);
    final b = downloadEntry(cid: 2);
    var current = true;
    var callbacks = 0;
    final helper = DownloadDeletion();
    final pending = helper.run(
      items: [a, b],
      delete: (entry) => service.deleteDownload(entry: entry),
      entries: (entry) => [entry],
      isCurrent: () => current,
      onDeleted: (_) => callbacks++,
    );
    current = false;
    service.replies.single.complete(const Success(null));
    expect(await pending, {a});
    expect(service.requests, [a]);
    expect(callbacks, 0);
    expect(helper.busy, false);
    await finish(tester);
  });
  testWidgets('分组批量部分成功刷新后仍保留失败组选择及播放记录', (tester) async {
    await mount(tester);
    final a = downloadEntry(aid: 1, cid: 1)..pageDirPath = 'page-a';
    final b = downloadEntry(aid: 2, cid: 2)..pageDirPath = 'page-b';
    service.downloadList.addAll([a, b]);
    final controller = DownloadPageController();
    addTearDown(controller.onDelete.call);
    await tester.runAsync(() async {
      controller.onInit();
      await Future<void>.delayed(Duration.zero);
    });
    expect(controller.pages, hasLength(2));
    controller.enableMultiSelect.value = true;
    controller.handleSelect(checked: true);
    await box.putAll({'1': 10, '2': 20});
    final pending = controller.removePages(controller.allChecked.toList());
    service.replies[0].complete(const Error('删除失败，请重试'));
    await tester.pump();
    expect(service.pageRequests, ['page-a', 'page-b']);
    service.replies[1].complete(const Success(null));
    await pending;
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(controller.pages.map((page) => page.pageId), ['1']);
    expect(controller.pages.single.checked, true);
    expect(controller.checkedCount, 1);
    expect(controller.enableMultiSelect.value, true);
    expect(box.get('1'), 10);
    expect(box.get('2'), isNull);
    final retry = controller.removePages(controller.allChecked.toList());
    service.replies[2].complete(const Success(null));
    await retry;
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(controller.pages, isEmpty);
    expect(controller.checkedCount, 0);
    expect(controller.enableMultiSelect.value, false);
    await finish(tester);
  });
  testWidgets('本地刷新回调失败不覆盖成功且继续删除后续项', (tester) async {
    await mount(tester);
    final a = downloadEntry(cid: 1);
    final b = downloadEntry(cid: 2);
    final helper = DownloadDeletion();
    final callbacks = <BiliDownloadEntryInfo>[];
    final result = await helper.run(
      items: [a, b],
      delete: (_) async => const Success<void>(null),
      entries: (entry) => [entry],
      isCurrent: () => true,
      onDeleted: (entry) {
        callbacks.add(entry);
        if (entry == a) throw StateError('private-refresh');
      },
    );
    expect(result, {a, b});
    expect(callbacks, [a, b]);
    expect(helper.busy, false);
    await tester.pumpAndSettle();
    expect(find.text('下载已删除，请刷新列表'), findsOneWidget);
    expect(find.textContaining('private-refresh'), findsNothing);
    await finish(tester);
  });
}

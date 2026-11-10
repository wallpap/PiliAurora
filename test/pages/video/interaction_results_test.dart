import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/video/video_detail/stat.dart';
import 'package:pili_aurora/models/remote/video/video_detail/stat_detail.dart';
import 'package:pili_aurora/models/remote/video/video_detail/staff.dart';
import 'package:pili_aurora/pages/video/introduction/pgc/controller.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Ugc extends UgcIntroController {
  final stat = VideoStat.fromJson({});
  @override
  StatDetail getStat() => stat;
  @override
  bool get isShowOnlineTotal => true;
}

class _Pgc extends PgcIntroController {
  final stat = VideoStat.fromJson({});
  @override
  StatDetail getStat() => stat;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final controllers = <GetxController>[];
  LoginAccount account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    'fixture-access-$id',
    null,
  );
  late Account original;
  T own<T extends GetxController>(T controller) {
    controllers.add(controller);
    return controller;
  }

  _Ugc ugc() => own(_Ugc()..bvid = IdUtils.av2bv(1));
  _Pgc pgc() => own(
    _Pgc()
      ..bvid = IdUtils.av2bv(1)
      ..epId = 1,
  );
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
    original = account(1);
    Accounts.accountMode[AccountType.main.index] = original;
    GlobalData().coins = 10;
    requests.clear();
  });
  tearDown(() {
    for (final controller in controllers) {
      controller.onDelete();
    }
    controllers.clear();
    GlobalData().coins = null;
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
  }

  Future<void> finish(WidgetTester tester) async {
    final dismissed = SmartDialog.dismiss(status: .allToast);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await dismissed;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('点赞等待真实回执，四种互动互斥并拒绝早先查询覆盖', (tester) async {
    await mount(tester);
    final controller = ugc();
    await tester.runAsync(() async {
      final reading = controller.queryAllStatus();
      await interceptor.waitForRequests(1);
      final writing = controller.actionLikeVideo();
      await interceptor.waitForRequests(2);
      await controller.actionLikeVideo();
      await controller.actionTriple();
      await controller.actionDislikeVideo();
      await controller.onPayCoin(1, true);
      expect(requests, hasLength(2));
      expect(controller.hasLike.value, isFalse);
      requests[1].reply.complete({'code': 0});
      await writing;
      requests[0].reply.complete({
        'code': 0,
        'data': {'like': false, 'favorite': false, 'dislike': false, 'coin': 0},
      });
      await reading;
    });
    await tester.pump();
    expect(controller.hasLike.value, isTrue);
    expect(controller.stat.like, 1);
    expect(find.text('点赞成功'), findsOneWidget);
    await finish(tester);
  });
  testWidgets('投币与三连使用实际数量，部分成功保留已完成项', (tester) async {
    await mount(tester);
    final controller = ugc()..coinNum.value = 1;
    await tester.runAsync(() async {
      final writing = controller.actionTriple();
      await interceptor.waitForRequests(1);
      requests[0].reply.complete({
        'code': 0,
        'data': {'like': true, 'coin': true, 'fav': false, 'multiply': 1},
      });
      await writing;
    });
    await tester.pump();
    expect(controller.coinNum.value, 2);
    expect(controller.stat.coin, 1);
    expect(GlobalData().coins, 9);
    expect(controller.hasLike.value, isTrue);
    expect(controller.hasFav.value, isFalse);
    expect(find.text('三连未全部完成，请核对点赞、投币和收藏状态'), findsOneWidget);
    await finish(tester);
  });
  testWidgets('PGC 回执按投币状态快照计算新增数量，不把单币记成双币', (tester) async {
    await mount(tester);
    final controller = pgc()..coinNum.value = 1;
    await tester.runAsync(() async {
      final writing = controller.actionTriple();
      await interceptor.waitForRequests(1);
      requests[0].reply.complete({
        'code': 0,
        'data': {'like': 1, 'coin': 1, 'favorite': 1, 'coin_number': 2},
      });
      await writing;
    });
    expect(controller.coinNum.value, 2);
    expect(controller.stat.coin, 1);
    expect(GlobalData().coins, 9);
    expect(controller.hasTriple, isTrue);
    await finish(tester);
  });
  testWidgets('拒绝和结果待确认保留状态，完成后可重新操作', (tester) async {
    await mount(tester);
    final controller = ugc();
    for (final (body, message) in [
      ({'code': -403, 'message': '拒绝点赞'}, '拒绝点赞'),
      ({'code': '0'}, '操作结果待确认，请先核对后再操作'),
    ]) {
      await tester.runAsync(() async {
        final count = requests.length + 1;
        final writing = controller.actionLikeVideo();
        await interceptor.waitForRequests(count);
        requests.last.reply.complete(body);
        await writing;
        expect(controller.hasLike.value, isFalse);
        expect(controller.stat.like, 0);
        expect(controller.interactionBusy, isFalse);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      final dismissed = SmartDialog.dismiss(status: .allToast);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await dismissed;
    }
    await finish(tester);
  });
  testWidgets('换视频后的成功只结算原账号余额，切号后的成功不写新账号', (tester) async {
    await mount(tester);
    final controller = ugc();
    await tester.runAsync(() async {
      var writing = controller.onPayCoin(1, true);
      await interceptor.waitForRequests(1);
      controller.bvid = IdUtils.av2bv(2);
      requests[0].reply.complete({'code': 0});
      await writing;
      expect(GlobalData().coins, 9);
      expect(controller.coinNum.value, 0);
      expect(controller.hasLike.value, isFalse);
      writing = controller.actionTriple();
      await interceptor.waitForRequests(2);
      Accounts.accountMode[AccountType.main.index] = account(2);
      GlobalData().coins = 20;
      requests[1].reply.complete({
        'code': 0,
        'data': {'like': true, 'coin': true, 'fav': true, 'multiply': 2},
      });
      await writing;
      expect(GlobalData().coins, 20);
      expect(controller.hasTriple, isFalse);
      expect(requests[1].options.extra['account'], same(original));
    });
    await finish(tester);
  });
  testWidgets('PGC 切集和页面释放后忽略迟到结果，旧投币面板不提交', (tester) async {
    await mount(tester);
    final controller = pgc();
    final callback = controller.payCoinCallback;
    await tester.runAsync(() async {
      final writing = controller.actionLikeVideo();
      await interceptor.waitForRequests(1);
      controller.epId = 2;
      requests[0].reply.complete({'code': 0});
      await writing;
      expect(controller.hasLike.value, isFalse);
      await callback(1, true);
      expect(requests, hasLength(1));
      final reading = controller.queryPgcLikeCoinFav();
      await interceptor.waitForRequests(2);
      controller.onDelete();
      requests[1].reply.complete({
        'code': 0,
        'data': {'like': 1, 'favorite': 1, 'coin_number': 2},
      });
      await reading;
      expect(controller.hasTriple, isFalse);
    });
    await finish(tester);
  });
  test('视频与分P变更后忽略迟到标签、在线人数和合作关系查询', () async {
    final controller = ugc()..cid = 1.obs;
    final tags = controller.queryVideoTags();
    await interceptor.waitForRequests(1);
    final online = controller.queryOnlineTotal();
    await interceptor.waitForRequests(2);
    final relations = controller.queryUserStat([Staff(mid: 1)]);
    await interceptor.waitForRequests(3);
    controller.bvid = IdUtils.av2bv(2);
    controller.cid.value = 2;
    requests[0].reply.complete({
      'code': 0,
      'data': [
        {'tag_id': 1, 'tag_name': 'old tag'},
      ],
    });
    requests[1].reply.complete({
      'code': 0,
      'data': {'total': '100'},
    });
    requests[2].reply.complete({
      'code': 0,
      'data': {
        '1': {'attribute': 2},
      },
    });
    await Future.wait([tags, online, relations]);
    expect(controller.videoTags.value, isNull);
    expect(controller.total.value, '1');
    expect(controller.staffRelations, isEmpty);
  });
  test('标签读取失败保留已有快照，关闭后简介结果不继续派生查询', () async {
    final controller = ugc()..cid = 1.obs;
    var reading = controller.queryVideoTags();
    await interceptor.waitForRequests(1);
    requests[0].reply.complete({
      'code': 0,
      'data': [
        {'tag_id': 1, 'tag_name': 'tag'},
      ],
    });
    await reading;
    final previous = controller.videoTags.value;
    reading = controller.queryVideoTags();
    await interceptor.waitForRequests(2);
    requests[1].reply.complete({'code': -403, 'message': '拒绝查询'});
    await reading;
    expect(controller.videoTags.value, same(previous));
    // 简介查询还会独立读取标签；固定签名缓存避免夹具依赖导航请求。
    await GStorage.localCache.putAll({
      LocalCacheKey.mixinKey: 'fixture-key',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    final introduction = controller.queryVideoIntro();
    await interceptor.waitForRequests(4);
    controller.onDelete();
    requests[2].reply.complete({'code': 0, 'data': []});
    requests[3].reply.complete({'code': -403, 'message': '拒绝简介'});
    await introduction;
    expect(requests, hasLength(4));
    expect(controller.status.value, isTrue);
  });
}

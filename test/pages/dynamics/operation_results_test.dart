import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/models/dynamics/vote_model.dart'
    show VoteInfo, Option;
import 'package:pili_aurora/pages/dynamics/widgets/additional_panel.dart';
import 'package:pili_aurora/pages/dynamics/widgets/vote.dart';
import 'package:pili_aurora/pages/dynamics_detail/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  Account account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    null,
    null,
  );
  final original = account(1);
  final replacement = account(2);
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    GStorage.userInfo = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = original;
    requests.clear();
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  Future<void> mount(WidgetTester tester, [Widget? child]) async {
    addTearDown(() async {
      final dismissal = SmartDialog.dismiss(status: .allToast);
      await tester.pumpAndSettle();
      await dismissal;
    });
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: Scaffold(body: child ?? const SizedBox()),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    await tester.pump();
  }

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    final end = tester.binding.clock.now().add(const Duration(seconds: 3));
    while (!condition() && tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(condition(), isTrue);
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    final dismissal = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissal;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  DynamicItemModel item() => DynamicItemModel.fromJson({
    'id_str': '1',
    'modules': {
      'module_author': {
        'icon_badge': {'text': '仅自己可见'},
      },
      'module_stat': {
        'like': {'status': true, 'count': 0},
      },
    },
  });

  testWidgets('动态点赞共用在途状态，待确认不改计数，成功不产生负数且切号拒绝旧结果', (tester) async {
    await mount(tester);
    final dynamic = item();
    final like = dynamic.modules.moduleStat!.like!;
    var changes = 0;
    final pending = RequestUtils.onLikeDynamic(dynamic, true, () => changes++);
    await RequestUtils.onLikeDynamic(dynamic, true, () => changes++);
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete({'code': '0'});
    await settle(tester);
    await pending;
    expect(changes, 0);
    expect(like.status, isTrue);
    expect(like.count, 0);
    final retry = RequestUtils.onLikeDynamic(dynamic, true, () => changes++);
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    await retry;
    expect(changes, 1);
    expect(like.status, isFalse);
    expect(like.count, 0);
    final stale = RequestUtils.onLikeDynamic(dynamic, false, () => changes++);
    await until(tester, () => requests.length == 3);
    Accounts.accountMode[AccountType.main.index] = replacement;
    requests[2].reply.complete({'code': 0});
    await settle(tester);
    await stale;
    expect(changes, 1);
    expect(like.status, isFalse);
    expect(
      requests.every(
        (request) => identical(request.options.extra['account'], original),
      ),
      isTrue,
    );
    await finish(tester);
  });

  testWidgets('动态可见范围保存互斥，待确认和换动态后的迟到成功不更新标签', (tester) async {
    await mount(tester);
    final dynamic = item();
    final controller = DynamicDetailController()..dynItem = dynamic;
    addTearDown(controller.onDelete.call);
    final pending = controller.onSetPubSetting(true, '1');
    expect(await controller.onSetPubSetting(true, '1'), isA<Error>());
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete({'code': '0'});
    await settle(tester);
    expect(await pending, isA<UnknownResult>());
    expect(dynamic.modules.moduleAuthor!.badgeText, '仅自己可见');
    final stale = controller.onSetPubSetting(true, '1');
    await until(tester, () => requests.length == 2);
    controller.dynItem = item();
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    expect(await stale, isA<Error>());
    expect(dynamic.modules.moduleAuthor!.badgeText, '仅自己可见');
    await finish(tester);
  });

  testWidgets('投票提交冻结选项并处理回调异常，切号后的成功不消费', (tester) async {
    final info = VoteInfo(
      title: '投票',
      voteId: 7,
      choiceCnt: 1,
      endTime:
          DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
          1000,
      options: [
        Option.fromJson({'opt_idx': 1, 'opt_desc': '甲'}),
        Option.fromJson({'opt_idx': 2, 'opt_desc': '乙'}),
      ],
    );
    var calls = 0;
    final reply = Completer<LoadingState<VoteInfo>>();
    await mount(
      tester,
      SizedBox(
        height: 450,
        child: VotePanel(
          voteInfo: info,
          onVote: (votes, anonymous) {
            calls++;
            expect(votes, {1});
            if (calls == 1) throw StateError('fixture');
            return reply.future;
          },
        ),
      ),
    );
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete({'code': 0});
    await settle(tester);
    await tester.tap(find.text('甲'));
    await tester.pump();
    await tester.tap(find.byType(OutlinedButton));
    await settle(tester);
    expect(calls, 1);
    expect(tester.takeException(), isNull);
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);
    await tester.tap(find.byType(OutlinedButton));
    await tester.pump();
    expect(calls, 2);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('乙'));
    await tester.pump();
    Accounts.accountMode[AccountType.main.index] = replacement;
    reply.complete(Success(info));
    await settle(tester);
    expect(find.text('账号已切换，请重新打开投票'), findsOneWidget);
    expect(find.text('已完成'), findsNothing);
    await finish(tester);
  });

  testWidgets('预约防重复提交，可选回执缺失保留旧数据，切号不回写', (tester) async {
    final reserve = Reserve(
      title: '预约',
      rid: 7,
      reserveTotal: 8,
      desc2: Desc(text: '已有八人预约'),
      button: ReserveBtn(status: 0, type: 1),
    );
    await mount(
      tester,
      Builder(
        builder: (context) => addWidget(
          context,
          floor: 1,
          theme: Theme.of(context),
          idStr: '1',
          additional: DynamicAddModel(
            type: 'ADDITIONAL_TYPE_RESERVE',
            reserve: reserve,
          ),
        )!,
      ),
    );
    await tester.tap(find.text('预约').last);
    await until(tester, () => requests.length == 1);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    requests[0].reply.complete({
      'code': 0,
      'data': {'final_btn_status': 1},
    });
    await settle(tester);
    expect(reserve.button!.status, 1);
    expect(reserve.reserveTotal, 8);
    expect(reserve.desc2!.text, '已有八人预约');
    await tester.tap(find.text('已预约'));
    await until(tester, () => requests.length == 2);
    Accounts.accountMode[AccountType.main.index] = replacement;
    requests[1].reply.complete({
      'code': 0,
      'data': {'final_btn_status': 0, 'reserve_update': 0},
    });
    await settle(tester);
    expect(reserve.button!.status, 1);
    expect(reserve.reserveTotal, 8);
    await finish(tester);
  });
}

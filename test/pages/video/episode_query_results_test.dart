import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/video/video_detail/episode.dart';
import 'package:pili_aurora/pages/common/common_intro_controller.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/video/introduction/pgc/controller.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/controller.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Owner implements PlaybackOwner {
  int generation = 0;
  @override
  bool Function() guard() {
    final value = generation;
    return () => value == generation;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Video extends GetxController implements VideoDetailController {
  @override
  final _Owner playbackOwner = _Owner();
  @override
  String bvid = 'BV17x411w7KC';
  @override
  final cid = 1.obs;
  final unexpectedCalls = <Symbol>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls.add(invocation.memberName);
    return super.noSuchMethod(invocation);
  }
}

class _Ugc extends UgcIntroController {
  _Ugc(this.video);
  final _Video video;
  @override
  VideoDetailController get videoDetailCtr => video;
}

class _Pgc extends PgcIntroController {
  _Pgc(this.video);
  final _Video video;
  @override
  VideoDetailController get videoDetailCtr => video;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  Account account() => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'fixture'}),
    null,
    null,
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
    requests.clear();
    Accounts.accountMode[AccountType.main.index] = account();
    Accounts.accountMode[AccountType.heartbeat.index] = account();
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 300 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(ready(), isTrue);
  }

  for (final pgc in [false, true]) {
    late CommonIntroController controller;
    late _Video video;
    Future<void> mount(WidgetTester tester) async {
      video = _Video();
      controller = (pgc ? _Pgc(video) : _Ugc(video))
        ..bvid = video.bvid
        ..cid = 1.obs;
      await tester.pumpWidget(
        GetMaterialApp(
          builder: FlutterSmartDialog.init(),
          home: const Scaffold(),
        ),
      );
    }

    Future<bool> change() {
      final episode = BaseEpisodeItem(aid: 123, epId: 2, cid: 0);
      return pgc
          ? (controller as PgcIntroController).onChangeEpisode(episode)
          : (controller as UgcIntroController).onChangeEpisode(episode);
    }

    Future<void> finish(WidgetTester tester) async {
      controller.onDelete();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      expect(video.unexpectedCalls, isEmpty);
    }

    testWidgets('${pgc ? 'PGC' : 'UGC'} 分P查询失败可重试，空结果明确提示且不修改播放', (
      tester,
    ) async {
      await mount(tester);
      var pending = change();
      await until(tester, () => requests.length == 1);
      expect(requests[0].options.extra['account'], same(Accounts.heartbeat));
      requests[0].reply.complete({'code': -404, 'message': '分P查询失败'});
      await until(tester, () => find.text('分P查询失败').evaluate().isNotEmpty);
      expect(await pending, isFalse);
      pending = change();
      await until(tester, () => requests.length == 2);
      requests[1].reply.complete({'code': 0, 'data': []});
      await until(
        tester,
        () =>
            find.text(pgc ? '该分集暂无可播放内容' : '该视频暂无可播放分 P').evaluate().isNotEmpty,
      );
      expect(await pending, isFalse);
      await finish(tester);
    });
    testWidgets('${pgc ? 'PGC' : 'UGC'} 最近切集操作生效，旧查询不再覆盖或提示', (tester) async {
      await mount(tester);
      final old = change();
      await until(tester, () => requests.length == 1);
      final latest = change();
      await until(tester, () => requests.length == 2);
      requests[1].reply.complete({'code': 0, 'data': []});
      await until(
        tester,
        () =>
            find.text(pgc ? '该分集暂无可播放内容' : '该视频暂无可播放分 P').evaluate().isNotEmpty,
      );
      expect(await latest, isFalse);
      requests[0].reply.complete({'code': -404, 'message': '旧错误'});
      await tester.pumpAndSettle();
      expect(await old, isFalse);
      expect(find.text('旧错误'), findsNothing);
      await finish(tester);
    });
    for (final mode in ['主账号', '记录账号', '分P', '离页返回', '关闭']) {
      testWidgets('${pgc ? 'PGC' : 'UGC'} $mode 变化后静默丢弃旧查询', (tester) async {
        await mount(tester);
        final pending = change();
        await until(tester, () => requests.length == 1);
        switch (mode) {
          case '主账号':
            Accounts.accountMode[AccountType.main.index] = account();
          case '记录账号':
            Accounts.accountMode[AccountType.heartbeat.index] = account();
          case '分P':
            video.cid.value = 99;
          case '离页返回':
            video.playbackOwner.generation++;
          case '关闭':
            controller.onDelete();
        }
        requests[0].reply.complete(
          mode == '分P' || mode == '离页返回'
              ? {
                  'code': 0,
                  'data': [
                    {'cid': 123},
                  ],
                }
              : {'code': -404, 'message': '旧错误'},
        );
        await tester.pumpAndSettle();
        expect(await pending, isFalse);
        expect(find.text('旧错误'), findsNothing);
        await finish(tester);
      });
    }
  }
}

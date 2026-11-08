import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:pili_aurora/pages/video/widgets/danmaku_like_control.dart';
import 'package:pili_aurora/common/widgets/custom_icon.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/display_binding.dart';
import 'package:pili_aurora/pages/danmaku/interaction.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/controller.dart';
import 'package:pili_aurora/pages/video/widgets/header_control.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

void main() {
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
  });
  testWidgets(
    'pool refresh obtains the current handle after seek and media replacement',
    (tester) async {
      Get.put<UgcIntroController>(_Intro(), tag: 'pool-test');
      final renderer = DanmakuWindowRenderer<DanmakuExtra>(
        option: const DanmakuOption(),
        size: const Size(640, 360),
      );
      renderer
        ..prepare(
          [
            DanmakuWindowContent(
              'one',
              0,
              DanmakuContentItem<DanmakuExtra>(
                'visible comment',
                extra: VideoDanmaku(id: 7, mid: 'self'),
              ),
            ),
          ],
          generation: renderer.generation,
          preparedUntilUs: 2000000,
        )
        ..present(0);
      final player = _Player()
        ..danmakuDisplay = DanmakuDisplayBinding(
          interaction: () => renderer.interaction,
          clear: () => renderer.reset(0),
        );
      await tester.pumpWidget(
        MaterialApp(builder: FlutterSmartDialog.init(), home: _Header(player)),
      );
      tester.state<_HeaderState>(find.byType(_Header)).showDanmakuPool();
      await tester.pump();
      expect(find.text('visible comment'), findsOneWidget);
      renderer
        ..suspendPresentation()
        ..present(100000);
      await tester.tap(find.byIcon(Icons.refresh).first);
      await tester.pump();
      expect(find.text('visible comment'), findsOneWidget);
      player.danmakuDisplay = null;
      await tester.tap(find.byIcon(Icons.refresh).first);
      await tester.pump();
      expect(find.text('visible comment'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      renderer.dispose();
      Get.reset();
    },
  );
  testWidgets('reopening playback restores the current user danmaku like', (
    tester,
  ) async {
    final oldAccount = Accounts.main;
    Accounts.accountMode[0] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '123', 'bili_jct': 'fixture'}),
      null,
      null,
    );
    Request();
    Request.dio.interceptors.clear();
    final requests = <RequestOptions>[];
    RequestInterceptorHandler? pendingStats;
    Request.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          if (options.method == 'GET') {
            pendingStats = handler;
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              data: {
                'code': 0,
                'data': {
                  '7': {'likes': 12, 'user_like': 1},
                },
              },
            ),
          );
        },
      ),
    );
    Get.put<UgcIntroController>(_Intro(), tag: 'pool-test');
    final renderer = DanmakuWindowRenderer<DanmakuExtra>(
      option: const DanmakuOption(),
      size: const Size(640, 360),
    );
    final extra = VideoDanmaku(id: 7, mid: 'self');
    renderer
      ..prepare(
        [
          DanmakuWindowContent(
            'one',
            0,
            DanmakuContentItem<DanmakuExtra>(
              'liked before playback',
              extra: extra,
            ),
          ),
        ],
        generation: renderer.generation,
        preparedUntilUs: 2000000,
      )
      ..present(0);
    final player = _Player()
      ..danmakuDisplay = DanmakuDisplayBinding(
        interaction: () => renderer.interaction,
        clear: () => renderer.reset(0),
      );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      renderer.dispose();
      Get.reset();
      Accounts.accountMode[0] = oldAccount;
      Request.dio.interceptors.clear();
    });
    await tester.pumpWidget(
      MaterialApp(builder: FlutterSmartDialog.init(), home: _Header(player)),
    );
    tester.state<_HeaderState>(find.byType(_Header)).showDanmakuPool();
    await tester.pump();
    expect(find.byIcon(CustomIcons.player_dm_tip_like), findsNothing);
    await tester.pump(const Duration(milliseconds: 20));
    // 首帧和慢请求期间都不能把未知状态画成“未点赞”。
    expect(find.byIcon(CustomIcons.player_dm_tip_like), findsNothing);
    expect(find.byIcon(CustomIcons.player_dm_tip_like_solid), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byIcon(CustomIcons.player_dm_tip_like), findsNothing);
    pendingStats!.resolve(
      Response(
        requestOptions: requests.single,
        data: {
          'code': 0,
          'data': {
            '7': {'likes': 12, 'user_like': 1},
          },
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byIcon(CustomIcons.player_dm_tip_like_solid), findsOneWidget);
    expect(extra.isLike, isTrue);
    expect(extra.like, 12);
    expect(requests.single.path, '/x/v2/dm/thumbup/stats');
    expect(requests.single.queryParameters, {'oid': 99, 'ids': '7'});
    await tester.tap(find.byIcon(CustomIcons.player_dm_tip_like_solid));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(requests.last.method, 'POST');
    expect(requests.last.data['op'], 2);
    expect(extra.isLike, isFalse);
    expect(extra.like, 11);
    expect(find.byIcon(CustomIcons.player_dm_tip_like), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });
  testWidgets('late stats are isolated and loading blocks like operations', (
    tester,
  ) async {
    final oldAccount = Accounts.main;
    Accounts.accountMode[0] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '123', 'bili_jct': 'fixture'}),
      null,
      null,
    );
    final pending = <(RequestOptions, RequestInterceptorHandler)>[];
    Request.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          pending.add((options, handler));
        },
      ),
    );
    addTearDown(() {
      Accounts.accountMode[0] = oldAccount;
      Request.dio.interceptors.clear();
    });
    final first = VideoDanmaku(id: 7, mid: 'self');
    final second = VideoDanmaku(id: 8, mid: 'self');
    var toggles = 0;
    Widget control(VideoDanmaku extra) => MaterialApp(
      home: DanmakuLikeControl(
        extra: extra,
        cid: 99,
        onLike: () async {
          toggles++;
        },
        builder: (context, onLike) =>
            TextButton(onPressed: onLike, child: Text('${extra.like}')),
      ),
    );
    await tester.pumpWidget(control(first));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byType(TextButton), findsNothing);
    await tester.tap(find.byType(DanmakuLikeControl));
    expect(toggles, 0);
    await tester.pumpWidget(control(second));
    await tester.pump(const Duration(milliseconds: 20));
    void reply(int index, int id, int likes, int userLike) {
      final (options, handler) = pending[index];
      handler.resolve(
        Response(
          requestOptions: options,
          data: {
            'code': 0,
            'data': {
              '$id': {'likes': likes, 'user_like': userLike},
            },
          },
        ),
      );
    }

    reply(1, 8, 2, 0);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    reply(0, 7, 12, 1);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    expect(first.isLike, isFalse);
    expect(second.isLike, isFalse);
    expect(second.like, 2);
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byType(TextButton));
    await tester.pump(const Duration(milliseconds: 20));
    expect(toggles, 1);
    expect(pending, hasLength(2));
  });

  for (final networkError in [false, true]) {
    testWidgets('查询失败保持未知，重试只查询状态（网络异常：$networkError）', (tester) async {
      final oldAccount = Accounts.main;
      Accounts.accountMode[0] = LoginAccount(
        BiliCookieJar.fromJson({'DedeUserID': '123', 'bili_jct': 'fixture'}),
        null,
        null,
      );
      Request();
      Request.dio.interceptors.clear();
      final pending = <(RequestOptions, RequestInterceptorHandler)>[];
      Request.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => pending.add((options, handler)),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        Accounts.accountMode[0] = oldAccount;
        Request.dio.interceptors.clear();
      });
      final extra = VideoDanmaku(id: 7, mid: 'self');
      var toggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DanmakuLikeControl(
              extra: extra,
              cid: 99,
              onLike: () async => toggles++,
              builder: (context, onLike) => TextButton(
                onPressed: onLike,
                child: Text(extra.isLike ? '已点赞' : '未点赞'),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      final (options, handler) = pending.single;
      if (networkError) {
        handler.reject(DioException(requestOptions: options));
      } else {
        handler.resolve(
          Response(
            requestOptions: options,
            data: {'code': 0, 'data': <String, dynamic>{}},
          ),
        );
      }
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('未点赞'), findsNothing);
      expect(find.text('已点赞'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('重新获取弹幕点赞状态'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(toggles, 0);
      expect(pending, hasLength(2));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      pending.last.$2.resolve(
        Response(
          requestOptions: pending.last.$1,
          data: {
            'code': 0,
            'data': {
              '7': {'likes': 12, 'user_like': 1},
            },
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('已点赞'), findsOneWidget);
      expect(toggles, 0);
      await tester.tap(find.text('已点赞'));
      await tester.pump();
      expect(toggles, 1);
    });
  }
}

class _Header extends HeaderControl {
  _Header(PlPlayerController player)
    : super(
        controller: player,
        videoDetailCtr: _Detail(),
        heroTag: 'pool-test',
        isPortrait: true,
      );
  @override
  HeaderControlState createState() => _HeaderState();
}

class _HeaderState extends HeaderControlState {
  Widget? sheet;
  @override
  Widget build(BuildContext context) => Scaffold(body: sheet);
  @override
  Future<void> showBottomSheet(
    StatefulWidgetBuilder builder, {
    ValueGetter<EdgeInsets>? padding,
  }) async {
    setState(() => sheet = StatefulBuilder(builder: builder));
  }
}

class _Detail implements VideoDetailController {
  @override
  bool get isFileSource => false;
  @override
  bool get isUgc => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Intro extends GetxController implements UgcIntroController {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Player implements PlPlayerController {
  @override
  int get cid => 99;
  @override
  DanmakuDisplayBinding? danmakuDisplay;
  @override
  DanmakuInteractionHandle<DanmakuExtra>? get danmakuInteraction =>
      danmakuDisplay?.interaction();
  @override
  bool get darkVideoPage => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

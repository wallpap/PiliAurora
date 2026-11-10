import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/codec.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/format.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/stream.dart'
    as live;
import 'package:pili_aurora/models/remote/live/live_room_play_info/url_info.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

const _oldPreference = ['http_stream', 'flv', 'avc'];
const _failure = PlaybackFailure(
  category: PlaybackFailureCategory.network,
  operation: 'test.load',
  stage: PlaybackStage.opening,
  recoverable: true,
  cause: '加载失败',
);

class _Settings extends MemoryBox<dynamic> {
  _Settings()
    : super({
        SettingBoxKey.liveStream: _oldPreference,
        SettingBoxKey.enableMultiCdn: false,
      });
  bool failPreference = false;
  int preferenceWrites = 0;

  @override
  Future<void> put(dynamic key, dynamic value) async {
    if (key == SettingBoxKey.liveStream) {
      preferenceWrites++;
      if (failPreference) throw StateError('https://private/?token=secret');
    }
    await super.put(key, value);
  }
}

class _Runtime implements PlaybackRuntimePort {
  final _events = StreamController<PlaybackRuntimeEvent>.broadcast(sync: true);
  final _released = Completer<void>();
  final loads = <PlaybackPlan>[];
  Completer<bool>? nextLoad;

  @override
  int get runtimeId => 771;
  @override
  Duration? get position => Duration.zero;
  @override
  bool get shaderChangeRequiresRendererReset => false;
  @override
  Stream<PlaybackRuntimeEvent> get events => _events.stream;
  @override
  Future<void> get released => _released.future;

  @override
  Future<PlaybackRuntimeLoadResult> load(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
  ) async {
    loads.add(plan);
    final gate = nextLoad;
    nextLoad = null;
    final loaded = await (gate?.future ?? Future.value(true));
    return PlaybackRuntimeLoadResult(
      loaded: loaded,
      failure: loaded ? null : _failure,
      output: PlaybackOutputPreparation(
        strategy: loaded
            ? PlaybackOutputStrategy.prepared
            : PlaybackOutputStrategy.failed,
        evidence: 'live-source-test',
        outputEpoch: context.loadId,
        hasVideo: loaded,
      ),
    );
  }

  @override
  Future<PlaybackRuntimeCommandResult> setPlaying(
    bool playing,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackShutdownResult> shutdown() async {
    if (!_released.isCompleted) {
      _released.complete();
      unawaited(_events.close());
    }
    return const PlaybackShutdownResult.released();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// 使用真实会话的请求仲裁与回执，替代原生播放器装配和平台插件。
class _Player implements PlPlayerController {
  _Player(this.session);
  final PlaybackSession session;
  PlaybackPlan? preparedPlan;
  @override
  final onlyPlayAudio = false.obs;
  @override
  bool get wantsToPlay => session.currentSnapshot.intent.playing;
  @override
  PlaybackSnapshot get currentPlaybackSnapshot => session.currentSnapshot;
  @override
  String? get currentPlaybackContentKey => session.currentPlan?.contentKey;
  @override
  PlaybackPlan? get currentPlaybackPlan => preparedPlan;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final args = invocation.namedArguments;
    switch (invocation.memberName) {
      case #capturePlaybackConfiguration:
        return PlaybackConfiguration(
          audioOnly: args[#audioOnly] as bool? ?? false,
        );
      case #createPlaybackPlan:
        return PlaybackPlan(
          contentKey: args[#contentKey] as String,
          source: PlaybackSourceSnapshot.fromDataSource(
            args[#source] as DataSource,
          ),
          timeline: PlaybackTimeline(
            kind: args[#timelineKind] as PlaybackTimelineKind,
            seekPolicy: args[#seekPolicy] as PlaybackSeekPolicy,
          ),
          configuration: args[#configuration] as PlaybackConfiguration,
        );
      case #loadPlaybackPlan:
        preparedPlan = args[#plan] as PlaybackPlan;
        return (args[#owner] as PlaybackOwner).load(
          args[#plan] as PlaybackPlan,
          start: args[#start] as PlaybackStartPolicy,
        );
      case #closePlaybackOwner:
        (invocation.positionalArguments.single as PlaybackOwner).close();
        return null;
      case #activatePlaybackOwner:
        (invocation.positionalArguments.single as PlaybackOwner).activate();
        return null;
      case #playerStatus:
        return PlayerStatus.paused;
      case #preparePlaybackPlan:
        preparedPlan = args[#plan] as PlaybackPlan;
        return null;
      case #videoPlayerController:
      case #onPlaybackQueryReady:
        return null;
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

class _Room extends LiveRoomController {
  _Room(this.player) : super('source-results');
  final _Player player;
  @override
  _Player get plPlayerController => player;
  PlaybackPlan? restoredPlan;

  // 本组只装配播放所有者，避免消息及页面初始化查询干扰契约回归。
  @override
  // ignore: must_call_super
  void onInit() {
    playbackOwner = plPlayerController.session.attach();
    scrollController = ScrollController();
    isLogin = false;
    mid = 0;
  }

  @override
  Future<LoadResult> loadPlaybackPlanForRoute(
    PlaybackPlan plan, {
    required PlaybackStartPolicy start,
  }) async {
    restoredPlan = plan;
    return const LoadResult.ready(1);
  }
}

List<live.Stream> _streams() => [
  for (var i = 0; i < 2; i++)
    live.Stream(
      protocolName: i == 0 ? 'http_stream' : 'http_hls',
      format: [
        Format(
          formatName: i == 0 ? 'flv' : 'ts',
          codec: [
            CodecItem(
              codecName: i == 0 ? 'avc' : 'hevc',
              currentQn: i == 0 ? 80 : 400,
              acceptQn: [80, 400],
              baseUrl: '/live$i',
              urlInfo: [
                UrlInfo(host: 'https://media.example', extra: '?token=secret'),
              ],
            ),
          ],
        ),
      ],
    ),
];

Map<String, dynamic> _response({int qn = 150}) => {
  'code': 0,
  'data': {
    'room_id': 12,
    'uid': 33,
    'live_status': 1,
    'is_portrait': false,
    'playurl_info': {
      'playurl': {
        'stream': [
          {
            'protocol_name': 'http_hls',
            'format': [
              {
                'format_name': 'ts',
                'codec': [
                  {
                    'codec_name': 'hevc',
                    'current_qn': qn,
                    'accept_qn': [80, 150, 400],
                    'base_url': '/new',
                    'url_info': [
                      {
                        'host': 'https://media.example',
                        'extra': '?token=secret',
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  late _Settings settings;
  late _Runtime runtime;
  late PlaybackSession session;
  late _Room room;

  setUpAll(() {
    settings = _Settings();
    GStorage.setting = settings;
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
    Get.routing.args = 12;
  });
  setUp(() {
    settings
      ..failPreference = false
      ..preferenceWrites = 0;
    settings.data[SettingBoxKey.liveStream] = _oldPreference;
    Accounts.accountMode[AccountType.heartbeat.index] = AnonymousAccount();
    interceptor.requests.clear();
    runtime = _Runtime();
    session = PlaybackSession(runtime: runtime);
    room = _Room(_Player(session))
      ..onInit()
      ..stream = _streams()
      ..currentQn = 80
      ..videoUrl = 'confirmed-source';
    room.currentQnDesc.value = '流畅';
  });
  tearDown(() async {
    for (final request in interceptor.requests) {
      if (!request.reply.isCompleted) request.reply.complete({'code': -1});
    }
    room.onDelete();
    await session.shutdown();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; !condition() && i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(condition(), isTrue);
  }

  Future<T> complete<T>(WidgetTester tester, Future<T> operation) async {
    var done = false;
    operation.then((_) => done = true);
    await until(tester, () => done);
    return operation;
  }

  void check(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: FlutterSmartDialog.init(),
          home: const Scaffold(),
        ),
      );
      try {
        await body(tester);
      } finally {
        final dismiss = SmartDialog.dismiss(status: SmartStatus.allToast);
        await tester.pump(const Duration(seconds: 6));
        await dismiss;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    });
  }

  check('手动选源同步失败交付安全回执，确认选择与偏好保持且可重试', (tester) async {
    var result = await room.initLiveUrl(streamIndex: 99);
    expect(result.outcome, LoadOutcome.failed);
    expect(result.failure!.cause, isNot(contains('token')));
    expect(runtime.loads, isEmpty);
    room.stream[1].format[0].codec[0].urlInfo.clear();
    result = await room.initLiveUrl(streamIndex: 1);
    expect(result.outcome, LoadOutcome.failed);
    expect(room.streamIndex, 0);
    expect(room.currentQn, 80);
    expect(room.videoUrl, 'confirmed-source');
    expect(settings.preferenceWrites, 0);
    room.stream = _streams();
    result = await complete(tester, room.initLiveUrl(streamIndex: 1));
    expect(result.outcome, LoadOutcome.ready);
    expect(room.streamIndex, 1);
    expect(room.currentQn, 400);
    expect(settings.get(SettingBoxKey.liveStream), ['http_hls', 'ts', 'hevc']);
  });

  check('加载等待和失败不发布候选，重试 ready 后才确认线路与偏好', (tester) async {
    final gate = runtime.nextLoad = Completer<bool>();
    final pending = room.initLiveUrl(streamIndex: 1);
    await until(tester, () => runtime.loads.isNotEmpty);
    expect(room.streamIndex, 0);
    expect(room.currentQn, 80);
    expect(settings.preferenceWrites, 0);
    gate.complete(false);
    expect((await complete(tester, pending)).outcome, LoadOutcome.failed);
    expect(session.currentSnapshot.phase, PlaybackPhase.failed);
    expect(room.videoUrl, 'confirmed-source');
    expect(settings.get(SettingBoxKey.liveStream), _oldPreference);
    final retry = await complete(tester, room.initLiveUrl(streamIndex: 1));
    expect(retry.outcome, LoadOutcome.ready);
    expect(runtime.loads, hasLength(2));
    expect(room.streamIndex, 1);
    expect(settings.preferenceWrites, 1);
  });

  check('线路已加载但保存偏好失败保留 ready，提示安全且后续可重试保存', (tester) async {
    settings.failPreference = true;
    final result = await complete(tester, room.initLiveUrl(streamIndex: 1));
    expect(result.outcome, LoadOutcome.ready);
    expect(room.streamIndex, 1);
    expect(session.currentSnapshot.phase, PlaybackPhase.ready);
    expect(settings.get(SettingBoxKey.liveStream), _oldPreference);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('线路已切换，但偏好保存失败'), findsOneWidget);
    expect(find.textContaining('token=secret'), findsNothing);
    settings.failPreference = false;
    expect(
      (await complete(tester, room.initLiveUrl(streamIndex: 1))).outcome,
      LoadOutcome.ready,
    );
    expect(settings.preferenceWrites, 2);
  });

  for (final change in ['账号', '房间', 'owner', '线路列表', '路由']) {
    check('$change 失效后的迟到加载不确认选择或保存偏好', (tester) async {
      final gate = runtime.nextLoad = Completer<bool>();
      final pending = room.initLiveUrl(streamIndex: 1);
      await until(tester, () => runtime.loads.isNotEmpty);
      switch (change) {
        case '账号':
          Accounts.accountMode[AccountType.heartbeat.index] = LoginAccount(
            BiliCookieJar.fromJson({'DedeUserID': '2', 'bili_jct': 'fixture'}),
            null,
            null,
          );
        case '房间':
          room.roomId = 13;
        case 'owner':
          room.playbackOwner.invalidateRequests();
        case '线路列表':
          room.stream = _streams();
        case '路由':
          room.holdPlaybackForRoute();
      }
      gate.complete(true);
      expect((await complete(tester, pending)).outcome, LoadOutcome.superseded);
      expect(room.streamIndex, 0);
      expect(room.currentQn, 80);
      expect(room.videoUrl, 'confirmed-source');
      expect(settings.preferenceWrites, 0);
    });
  }

  for (final failed in [false, true]) {
    check('离页恢复保留已确认线路，忽略${failed ? '失败' : '等待'}中的同房间候选', (tester) async {
      expect(
        (await complete(tester, room.initLiveUrl())).outcome,
        LoadOutcome.ready,
      );
      final confirmed = room.videoUrl;
      final gate = runtime.nextLoad = Completer<bool>();
      final candidate = room.initLiveUrl(streamIndex: 1);
      await until(tester, () => runtime.loads.length == 2);
      if (failed) {
        gate.complete(false);
        expect((await complete(tester, candidate)).outcome, LoadOutcome.failed);
      }
      runtime._events.add(
        PlaybackRuntimeStateChanged(
          runtimeId: runtime.runtimeId,
          loadId: session.loadId,
          actual: const PlaybackActual(position: Duration(seconds: 5)),
        ),
      );
      room.holdPlaybackForRoute();
      await complete(tester, room.restorePlaybackAfterRoute());
      expect(room.restoredPlan!.source.currentVideoSource, confirmed);
      expect(room.streamIndex, 0);
      expect(settings.preferenceWrites, 1);
      if (!failed) {
        gate.complete(true);
        expect(
          (await complete(tester, candidate)).outcome,
          LoadOutcome.superseded,
        );
      }
    });
  }

  check('画质接口与原生加载失败均保留确认画质，重试成功采用服务端实际码率', (tester) async {
    final originalStreams = room.stream;
    final apiFailure = room.changeQn(400);
    await until(tester, () => interceptor.requests.isNotEmpty);
    expect(room.currentQn, 80);
    expect(interceptor.requests[0].options.queryParameters['qn'], 400);
    interceptor.requests[0].reply.complete({'code': -1, 'message': '暂不可用'});
    expect((await complete(tester, apiFailure)).outcome, LoadOutcome.failed);
    final gate = runtime.nextLoad = Completer<bool>();
    final nativeFailure = room.changeQn(400);
    await until(tester, () => interceptor.requests.length == 2);
    interceptor.requests[1].reply.complete(_response());
    await until(tester, () => runtime.loads.isNotEmpty);
    expect(identical(room.stream, originalStreams), isTrue);
    expect(room.currentQn, 80);
    gate.complete(false);
    expect((await complete(tester, nativeFailure)).outcome, LoadOutcome.failed);
    expect(identical(room.stream, originalStreams), isTrue);
    expect(room.currentQn, 80);
    final retry = room.changeQn(400);
    await until(tester, () => interceptor.requests.length == 3);
    interceptor.requests[2].reply.complete(_response());
    expect((await complete(tester, retry)).outcome, LoadOutcome.ready);
    expect(room.currentQn, 150);
    expect(room.streamIndex, 0);
    expect(room.formatIndex, 0);
    expect(room.codecIndex, 0);
    expect(room.acceptQnList.map((e) => e.code), [80, 150, 400]);
    expect(settings.preferenceWrites, 0);
    // 已确认且当前 ready 才能省略同码率查询。
    expect((await room.changeQn(150)).outcome, LoadOutcome.ready);
    expect(interceptor.requests, hasLength(3));
  });

  check('账号切换后的画质查询回包不进入原生加载或覆盖已确认列表', (tester) async {
    final originalStreams = room.stream;
    final pending = room.changeQn(400);
    await until(tester, () => interceptor.requests.isNotEmpty);
    Accounts.accountMode[AccountType.heartbeat.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '2', 'bili_jct': 'fixture'}),
      null,
      null,
    );
    interceptor.requests[0].reply.complete(_response());
    expect((await complete(tester, pending)).outcome, LoadOutcome.superseded);
    expect(runtime.loads, isEmpty);
    expect(identical(room.stream, originalStreams), isTrue);
    expect(room.currentQn, 80);
    expect(settings.preferenceWrites, 0);
  });

  check('迟到候选虽已 ready，旧确认画质仍须重查来源而非短路成功', (tester) async {
    await complete(tester, room.initLiveUrl());
    final gate = runtime.nextLoad = Completer<bool>();
    var current = true;
    final pending = room.initLiveUrl(streamIndex: 1, isCurrent: () => current);
    await until(tester, () => runtime.loads.length == 2);
    current = false;
    gate.complete(true);
    expect((await complete(tester, pending)).outcome, LoadOutcome.superseded);
    expect(session.currentSnapshot.phase, PlaybackPhase.ready);
    expect(room.currentQn, 80);
    final retry = room.changeQn(80);
    await until(tester, () => interceptor.requests.isNotEmpty);
    interceptor.requests[0].reply.complete(_response(qn: 80));
    expect((await complete(tester, retry)).outcome, LoadOutcome.ready);
    expect(runtime.loads, hasLength(3));
  });
}

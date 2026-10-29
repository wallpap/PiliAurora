import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/remote/video/video_play_info/subtitle.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _PlaybackAdapter adapter;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'pili-playback-lifecycle-',
    );
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
    GStorage.localCache = await Hive.openBox('cache');
    await GStorage.setting.put(SettingBoxKey.autoPlayEnable, true);
    await GStorage.localCache.put(
      LocalCacheKey.timeStamp,
      DateTime.now().millisecondsSinceEpoch,
    );
    await GStorage.localCache.put(LocalCacheKey.mixinKey, 'synthetic-test-key');
    Request();
    Request.dio.interceptors.clear();
    adapter = _PlaybackAdapter();
    Request.dio.httpClientAdapter = adapter;
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
    await directory.delete(recursive: true);
  });

  _VideoController page() => _VideoController()
    ..args = <String, Object>{}
    ..bvid = 'BV-test'
    ..aid = 1
    ..cid = 1.obs
    ..videoType = VideoType.ugc
    ..isFileSource = false
    ..isVertical = false.obs;

  test('快速切集执行新请求，旧响应不能初始化新集', () async {
    final controller = page();
    final old = controller.queryVideoUrl();
    final first = await adapter.next();
    expect(first.options.queryParameters['cid'], 1);
    controller.cid.value = 2;
    final current = controller.queryVideoUrl();
    final second = await adapter.next();
    expect(second.options.queryParameters['cid'], 2);
    second.complete(media(2));
    await current;
    expect(first.cancelled, isTrue);
    first.complete(media(1));
    await old;
    expect(controller.loads.map((e) => e.cid), [2]);
    expect(controller.videoUrl, contains('/2'));
    controller.closePlayback();
  });

  for (final preload in [false, true]) {
    test('关闭自动播放且预加载为 $preload 时按设置加载并保留暂停意图', () async {
      await GStorage.setting.put(SettingBoxKey.preInitPlayer, preload);
      final controller = page()..autoPlay = false;
      final query = controller.queryVideoUrl();
      (await adapter.next()).complete(media(1));
      await query;
      expect(controller.videoUrl, contains('/1'));
      expect(controller.loads.length, preload ? 1 : 0);
      if (preload) expect(controller.loads.single.autoplay, isFalse);
      expect(controller.plPlayerController.preInitPlayer, preload);
      controller.closePlayback();
      await GStorage.setting.put(SettingBoxKey.preInitPlayer, false);
    });
  }

  test('媒体计划读取新的同步设置和缓冲偏好，已捕获计划保持稳定', () async {
    final controller = page();
    final first = controller.plPlayerController.capturePlaybackConfiguration(
      live: false,
    );
    await GStorage.setting.putAll({
      SettingBoxKey.videoSync: 'audio',
      SettingBoxKey.autosync: '30',
      SettingBoxKey.bufferSec: 24.0,
      SettingBoxKey.bufferSize: 8.0,
    });
    final next = controller.plPlayerController.capturePlaybackConfiguration(
      live: false,
    );
    expect(next.mediaOptions['video-sync'], 'audio');
    expect(next.mediaOptions['autosync'], '30');
    expect(next.mediaOptions['cache-secs'], '24.000');
    expect(next.mediaOptions['demuxer-max-bytes'], '${8 * 1024 * 1024}');
    expect(first.mediaOptions['video-sync'], 'display-resample');
    controller.closePlayback();
    await GStorage.setting.deleteAll([
      SettingBoxKey.videoSync,
      SettingBoxKey.autosync,
      SettingBoxKey.bufferSec,
      SettingBoxKey.bufferSize,
    ]);
  });

  test('补充画质请求也绑定原媒体，迟到补充不能污染当前数据', () async {
    final controller = page();
    final old = controller.queryVideoUrl();
    (await adapter.next()).complete(media(1, supplement: true));
    final supplement = await adapter.next();
    expect(supplement.options.queryParameters['cid'], 1);
    expect(supplement.options.queryParameters['qn'], 64);
    controller.cid.value = 2;
    final current = controller.queryVideoUrl();
    (await adapter.next()).complete(media(2));
    await current;
    supplement.complete(media(1, quality: 64));
    await old;
    expect(controller.data.dash!.video!.map((e) => e.id), [80]);
    expect(controller.loads.map((e) => e.cid), [2]);
    controller.closePlayback();
  });

  test('页面关闭后的地址响应不加载，初始化入口也检查关闭状态', () async {
    final controller = page();
    final query = controller.queryVideoUrl();
    final response = await adapter.next();
    controller.closePlayback();
    response.complete(media(1));
    await query;
    expect(response.cancelled, isTrue);
    expect(controller.loads, isEmpty);
    await controller.initializeClosedPage();
  });

  test('从有音轨切到无音轨，暂停后切画质保持暂停', () async {
    final controller = page();
    final first = controller.queryVideoUrl();
    (await adapter.next()).complete(media(1));
    await first;
    expect(controller.currentAudioQa, isNotNull);
    controller.cid.value = 2;
    final second = controller.queryVideoUrl();
    (await adapter.next()).complete(media(2, audio: false));
    await second;
    expect(controller.currentAudioQa, isNull);
    await controller.plPlayerController.pause();
    controller.updatePlayer();
    expect(controller.loads.last.autoplay, isFalse);
    expect(controller.audioUrl, isEmpty);
    controller.closePlayback();
  });

  test('字幕响应迟到且列表已切集清空时，不缓存或应用旧字幕', () async {
    final controller = page();
    controller.subtitles.add(
      Subtitle(lan: 'zh-CN', subtitleUrl: '//example.com/subtitle'),
    );
    final loading = controller.setSubtitle(1);
    final request = await adapter.next();
    controller.cid.value = 2;
    controller.subtitles.clear();
    request.complete({'body': []}, raw: true);
    await loading;
    expect(controller.vttSubtitles, isEmpty);
    expect(controller.vttSubtitlesIndex.value, -1);
    controller.closePlayback();
  });

  test('重新解析已加载媒体时保留暂停，并提交暂停加载请求', () async {
    final controller = page();
    final initial = controller.queryVideoUrl();
    (await adapter.next()).complete(media(1));
    await initial;
    await controller.plPlayerController.pause();
    final reset = controller.queryVideoUrl(fromReset: true);
    (await adapter.next()).complete(media(1));
    await reset;
    expect(controller.loads.length, 2);
    expect(controller.loads.last.autoplay, isFalse);
    controller.closePlayback();
  });

  test('查询被新页面取代时，返回会用保留意图重新解析', () async {
    final controller = page();
    final holdForRoute = controller.holdPlaybackForRoute;
    final restoreAfterRoute = controller.restorePlaybackAfterRoute;
    holdForRoute();
    final restore = restoreAfterRoute();
    final request = await adapter.next();
    request.complete(media(1));
    await restore;

    expect(controller.loads, hasLength(1));
    expect(controller.loads.single.autoplay, isFalse);
    controller.closePlayback();
  });

  test('返回已有媒体时重新提交页面计划并保留上次进度', () async {
    final controller = page();
    final initial = controller.queryVideoUrl();
    (await adapter.next()).complete(media(1));
    await initial;
    controller
      ..playedTime = const Duration(seconds: 27)
      ..holdPlaybackForRoute();
    await controller.restorePlaybackAfterRoute();

    expect(controller.routeLoads, hasLength(1));
    expect(controller.routeLoads.single.start, PlaybackStartPolicy.preserve);
    expect(controller.routeLoads.single.plan.contentKey, 'ugc:BV-test:1');
    expect(
      controller.routeLoads.single.plan.reloadPosition,
      const Duration(seconds: 27),
    );
    controller.closePlayback();
  });

  test('字幕加载期间选择关闭，以最新选择为准', () async {
    final controller = page();
    controller.subtitles.add(
      Subtitle(lan: 'zh-CN', subtitleUrl: '//example.com/subtitle'),
    );
    final loading = controller.setSubtitle(1);
    final request = await adapter.next();
    await controller.setSubtitle(0);
    request.complete({'body': []}, raw: true);
    await loading;
    expect(controller.vttSubtitlesIndex.value, 0);
    expect(controller.vttSubtitles, isEmpty);
    controller.closePlayback();
  });
}

Map<String, Object?> media(
  int cid, {
  bool audio = true,
  bool supplement = false,
  int quality = 80,
}) => {
  'quality': quality,
  'timelength': 60000,
  'accept_quality': [80, 64],
  'support_formats': [
    {
      'quality': 80,
      'codecs': ['avc1'],
    },
    if (supplement)
      {
        'quality': 64,
        'codecs': ['avc1'],
      },
  ],
  'dash': {
    'video': [
      {
        'id': quality,
        'base_url': 'https://example.com/video/$cid',
        'codecs': 'avc1',
        'width': 1920,
        'height': 1080,
      },
    ],
    if (audio)
      'audio': [
        {'id': 30280, 'base_url': 'https://example.com/audio/$cid'},
      ],
  },
};

class _VideoController extends VideoDetailController {
  _VideoController() {
    playbackOwner = plPlayerController.attachPlaybackOwner();
    plPlayerController.cacheVideoQa = 80;
  }
  bool closed = false;
  int _queryGeneration = 0;
  int _routeLoadGeneration = 0;
  void Function()? _cancelQuery;
  final loads = <({int cid, String? source, bool autoplay})>[];
  final routeLoads = <({PlaybackPlan plan, PlaybackStartPolicy start})>[];
  @override
  bool get isClosed => closed;
  @override
  Future<LoadResult> submitPlaybackQuery(
    Future<PlaybackPlan?> Function(PlaybackQuery) resolve, {
    required PlaybackStartPolicy start,
    bool Function()? shouldLoad,
  }) async {
    _cancelQuery?.call();
    _cancelQuery = null;
    final generation = ++_queryGeneration;
    bool isCurrent() => generation == _queryGeneration && !closed;
    final query = PlaybackQuery(
      requestId: generation,
      isCurrent: isCurrent,
      registerCancel: (cancel) {
        if (isCurrent()) {
          _cancelQuery = cancel;
        } else {
          cancel();
        }
      },
    );
    final plan = await resolve(query);
    if (!isCurrent()) return const LoadResult.superseded();
    if (plan == null) return const LoadResult.noMedia();
    if (shouldLoad?.call() == false) return const LoadResult.noMedia();
    loads.add((
      cid: cid.value,
      source: plan.source.currentVideoSource,
      autoplay: switch (start) {
        PlaybackStartPolicy.play => true,
        PlaybackStartPolicy.pause => false,
        PlaybackStartPolicy.preserve => plPlayerController.wantsToPlay,
      },
    ));
    return LoadResult.ready(generation);
  }

  @override
  Future<void> playerInit({
    bool? autoplay,
    bool autoFullScreenFlag = false,
  }) async {
    loads.add((
      cid: cid.value,
      source: videoUrl,
      autoplay: autoplay ?? plPlayerController.wantsToPlay,
    ));
  }

  @override
  Future<LoadResult> loadPlaybackPlanForRoute(
    PlaybackPlan plan, {
    required PlaybackStartPolicy start,
    required void Function() onReady,
  }) async {
    routeLoads.add((plan: plan, start: start));
    return LoadResult.ready(++_routeLoadGeneration);
  }

  @override
  Future<CommandResult> applyPlaybackSubtitleTrack(
    PlaybackSubtitleTrack? track,
  ) async => const CommandResult.applied();

  @override
  void afterPlaybackReady(bool Function() valid) {}

  Future<void> initializeClosedPage() => super.playerInit();
  void closePlayback() {
    closed = true;
    _cancelQuery?.call();
    playbackOwner.close();
  }
}

class _PendingPlayback {
  _PendingPlayback(this.options);
  final RequestOptions options;
  final response = Completer<ResponseBody>();
  bool cancelled = false;
  void complete(Map<String, Object?> data, {bool raw = false}) =>
      response.complete(
        ResponseBody.fromString(
          jsonEncode(raw ? data : {'code': 0, 'data': data}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
}

class _PlaybackAdapter implements HttpClientAdapter {
  final _requests = <_PendingPlayback>[];
  Completer<void> _arrived = Completer<void>();
  Future<_PendingPlayback> next() async {
    if (_requests.isEmpty) await _arrived.future;
    final next = _requests.removeAt(0);
    if (_requests.isEmpty) _arrived = Completer<void>();
    return next;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final request = _PendingPlayback(options);
    cancelFuture?.then((_) => request.cancelled = true);
    _requests.add(request);
    if (!_arrived.isCompleted) _arrived.complete();
    return request.response.future;
  }

  @override
  void close({bool force = false}) {}
}

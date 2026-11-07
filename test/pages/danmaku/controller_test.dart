import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pili_aurora/services/danmaku/work_quota.dart';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/painting.dart';
import 'package:dio/dio.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/user/danmaku_rule.dart';
import 'package:pili_aurora/pages/danmaku/controller.dart';
import 'package:pili_aurora/pages/danmaku/raw_cache.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:pili_aurora/pages/danmaku/window_coordinator.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

class _Player implements PlPlayerController {
  _Player({this.mergeDanmaku = true});

  @override
  bool mergeDanmaku;
  @override
  RuleFilter filters = RuleFilter(['屏蔽'], [], {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DanmakuElem _dm(String text, int time) =>
    DanmakuElem(content: text, progress: time, mode: 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    GStorage.setting = _SettingsBox();
    GStorage.video = _SettingsBox();
    GStorage.localCache = _SettingsBox();
    Request();
    Request.dio.interceptors.clear();
    Request.dio.httpClientAdapter.close(force: true);
  });
  tearDownAll(() => Request.dio.close(force: true));

  test(
    'network bucket keeps later high weights and preserves time order',
    () async {
      final source = PlDanmakuController(
        1,
        _Player(mergeDanmaku: false),
        false,
      );
      addTearDown(source.dispose);
      await source.handleDanmaku([
        for (var i = 0; i < 40; i++) _dm('低权重$i', i)..weight = 1,
        _dm('高权重', 90)..weight = 11,
      ], segmentIndex: 0);
      final range = source.readRange(0, 100000);
      expect(range.entries.length, 12);
      expect(range.entries.last.element.content, '高权重');
      expect(
        range.entries.map((e) => e.positionUs),
        orderedEquals([
          for (var i = 0; i < 11; i++) i * 1000,
          90000,
        ]),
      );
    },
  );

  test('file worker promotions restore a representative evicted from a full bucket', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pili-priority-file-',
    );
    final file = File('${directory.path}/${PathUtils.danmakuName}');
    await file.writeAsBytes(
      DmSegMobileReply(
        elems: [
          _dm('等待提升', 0)..weight = 1,
          for (var i = 0; i < 120; i++) _dm('独立内容$i', i % 90)..weight = 9,
          for (var i = 0; i < 300; i++) _dm('其他时间$i', 1000 + i * 100),
          _dm('等待提升', 10000)..weight = 11,
        ],
      ).writeToBuffer(),
    );
    final source = PlDanmakuController(1, _FilePlayer(directory.path), true);
    addTearDown(() async {
      source.dispose();
      await file.delete();
      await directory.delete();
    });
    await source.ensureRange(0, 360000000);
    final range = source.readRange(0, 100000);
    expect(range.entries.length, 120);
    final restored = range.entries
        .singleWhere((e) => e.element.content == '等待提升')
        .element;
    expect(restored.weight, 11);
    expect(restored.count, 2);
    expect(restored.progress, 0);
  });

  test(
    'dense valid gRPC segment remains available after decode and processing',
    () async {
      final reply = DmSegMobileReply(
        elems: [
          for (var i = 0; i < 17502; i++)
            DanmakuElem(
              id: Int64(i + 1),
              progress: i * 18,
              mode: 1,
              fontsize: 25,
              color: 0xffffff,
              midHash: 'sender-hash',
              content: '正常弹幕$i',
              ctime: Int64(1700000000),
              weight: 5,
              action: '',
              pool: 0,
              idStr: '${i + 1}',
              attr: 0,
              extra: 'metadata' * 15,
            ),
        ],
      );
      Request.dio.httpClientAdapter = _DmAdapter()..reply = reply;
      final source = PlDanmakuController(1, _Player(), false);
      addTearDown(source.dispose);
      await source.ensureRange(0, 360000000);
      final range = source.readRange(0, 360000000);
      expect(range.isLoaded, isTrue);
      expect(range.entries, hasLength(reply.elems.length));
      expect(range.entries.first.element.content, '正常弹幕0');
      expect(range.entries.last.element.content, '正常弹幕17501');
    },
  );

  test('paused production source fails once and resumes on explicit successful retry', () async {
    final adapter = _DmAdapter()
      ..fail = true
      ..progress = 0;
    Request.dio.httpClientAdapter = adapter;
    final source = PlDanmakuController(1, _Player(), false);
    final renderer = DanmakuWindowRenderer<void>(
      option: const DanmakuOption(massiveMode: true),
      size: const Size(640, 360),
    );
    final coordinator = DanmakuWindowCoordinator<void>(
      source: source,
      renderer: renderer,
      contentOf: (element) =>
          DanmakuContentItem<void>(element.content, selfSend: true),
    );
    addTearDown(source.dispose);
    addTearDown(renderer.dispose);
    addTearDown(coordinator.dispose);
    final failed = Completer<void>();
    var updates = 0;
    final subscription = coordinator.updates.listen((_) {
      updates++;
      coordinator.prepareFrame(renderer, 0);
      renderer.present(0, allowUnprepared: true);
      if (coordinator.requestFailed && !failed.isCompleted) failed.complete();
    });
    addTearDown(subscription.cancel);
    coordinator.prepareFrame(renderer, 0);
    await failed.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(adapter.calls, 1);
    expect(updates, lessThan(10));
    expect(coordinator.needsPreparation, isFalse);
    adapter.fail = false;
    await source.ensureRange(0, 2000000);
    expect(renderer.interaction.snapshot.single.text, '重复');
    expect(coordinator.requestFailed, isFalse);
    expect(adapter.calls, 2);
    for (var i = 0; i < 8; i++) {
      coordinator.prepareFrame(renderer, 0);
    }
    expect(coordinator.needsPreparation, isFalse);
    expect(adapter.calls, 2);
  });

  test(
    'failed response has explicit coverage and a later request recovers',
    () async {
      final adapter = _DmAdapter()..fail = true;
      Request.dio.httpClientAdapter = adapter;
      final controller = PlDanmakuController(1, _Player(), false);
      addTearDown(controller.dispose);
      final states = <DanmakuCoverageState>[];
      final subscription = controller.changes.listen((event) {
        if (event.kind == DanmakuSourceChangeKind.coverage) {
          states.add(controller.readRange(0, 1000000).coverage.single.state);
        }
      });
      addTearDown(subscription.cancel);
      await controller.ensureRange(0, 1000000);
      expect(states, [
        DanmakuCoverageState.loading,
        DanmakuCoverageState.failed,
      ]);
      expect(
        controller.readRange(0, 1000000).coverage.single.state,
        DanmakuCoverageState.failed,
      );
      adapter.fail = false;
      await controller.ensureRange(0, 1000000);
      expect(controller.readRange(0, 1000000).isLoaded, isTrue);
      expect(adapter.calls, 2);
    },
  );

  test('文件范围读取经过排序worker，跨段计数与规则恢复保持一致', () async {
    final directory = Directory.systemTemp.createTempSync('pili-file-source-');
    final file = File('${directory.path}/${PathUtils.danmakuName}');
    await file.writeAsBytes(
      DmSegMobileReply(
        elems: [
          _dm('跨段重复', 360100),
          _dm('屏蔽内容', 360200),
          for (var i = 0; i < 600; i++) _dm('条目$i', 1000 + i * 100),
          _dm('跨段重复', 359900),
        ],
      ).writeToBuffer(),
    );
    final player = _FilePlayer(directory.path);
    final source = PlDanmakuController(1, player, true);
    addTearDown(() {
      source.dispose();
      file.deleteSync();
      directory.deleteSync();
    });
    await source.ensureRange(359000000, 361000000);
    final before = source.readRange(359000000, 361000000);
    expect(before.isLoaded, isTrue);
    expect(before.entries, hasLength(1));
    expect(before.entries.single.element.count, 2);
    player.filters = RuleFilter([], [], {});
    await source.refreshRules();
    final after = source.readRange(359000000, 361000000);
    expect(after.entries.map((e) => e.element.content), ['跨段重复', '屏蔽内容']);
    expect(after.entries.first.element.count, 2);
    await source.ensureRange(0, 2000000);
    expect(source.readRange(0, 2000000).isLoaded, isTrue);
    await file.writeAsBytes(
      DmSegMobileReply(elems: [_dm('文件已替换', 100)]).writeToBuffer(),
    );
    await source.ensureRange(0, 2000000);
    expect(
      source.readRange(0, 2000000).entries.single.element.content,
      '文件已替换',
    );
  });

  test('等待中的范围覆盖旧前瞻，完成当前段后处理最新目标', () async {
    final controller = _RangeTargetController();
    addTearDown(controller.dispose);
    final initial = controller.ensureRange(0, 4 * 360000000);
    await controller.entered.future;
    final obsolete = controller.ensureRange(10 * 360000000, 12 * 360000000);
    final latest = controller.ensureRange(20 * 360000000, 21 * 360000000);
    controller.resume.complete();
    await Future.wait([initial, obsolete, latest]);
    expect(controller.segments, [0, 20]);
  });

  test('范围需求跨段请求、复用已加载段并限制单次扩展', () async {
    final adapter = _DmAdapter();
    Request.dio.httpClientAdapter = adapter;
    final controller = PlDanmakuController(
      1,
      _Player(mergeDanmaku: false),
      false,
    );
    addTearDown(controller.dispose);
    await controller.ensureRange(359999000, 360000001);
    expect(adapter.calls, 2);
    expect(controller.readRange(359999000, 360000001).isLoaded, isTrue);
    await controller.ensureRange(359999000, 360000001);
    await controller.ensureRange(100, 100);
    expect(adapter.calls, 2);
    await controller.ensureRange(0, 3600000000);
    expect(adapter.calls, 4);
  });

  test('规则重算期间的范围需求复用原始数据，不重复回源', () async {
    final adapter = _DmAdapter();
    Request.dio.httpClientAdapter = adapter;
    final controller = PlDanmakuController(
      1,
      _Player(mergeDanmaku: false),
      false,
    );
    addTearDown(controller.dispose);
    await controller.ensureRange(0, 1000000);
    final rebuilding = controller.refreshRules();
    await controller.ensureRange(0, 1000000);
    await rebuilding;
    expect(adapter.calls, 1);
    expect(controller.readRange(0, 1000000).isLoaded, isTrue);
  });

  test('多个来源响应在同一预留内串行处理直到缓存提交', () async {
    final adapter = _DmAdapter();
    Request.dio.httpClientAdapter = adapter;
    final first = _HoldingController();
    final second = _HoldingController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final firstRequest = first.queryDanmaku(0);
    await first.entered.future;
    final secondRequest = second.queryDanmaku(0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(second.entered.isCompleted, isFalse);
    first.resume.complete();
    await firstRequest;
    await second.entered.future;
    expect(first.readRange(0, 1000000).isLoaded, isTrue);
    second.resume.complete();
    await secondRequest;
    expect(second.readRange(0, 1000000).isLoaded, isTrue);
  });

  test('等待队列满时保留来源需求，容量恢复后处理最新规则', () async {
    final quota = DanmakuWorkQuota.instance;
    final gate = Completer<void>();
    final running = quota.run(1, () => gate.future);
    final waiting = List.generate(
      quota.maxWaitingTasks,
      (_) => quota.run(1, () {}, waitingBytes: 1),
    );
    final player = _Player(mergeDanmaku: false);
    final controller = PlDanmakuController(1, player, false);
    addTearDown(controller.dispose);
    await controller.handleDanmaku([_dm('屏蔽内容', 100)], segmentIndex: 0);
    expect(controller.readRange(0, 1000000).isLoaded, isFalse);
    player.filters = RuleFilter.empty();
    await controller.refreshRules();
    final ready = controller.changes.firstWhere(
      (e) => e.kind == DanmakuSourceChangeKind.ready,
    );
    gate.complete();
    await running;
    await Future.wait(waiting);
    await ready.timeout(const Duration(seconds: 5));
    expect(controller.peekBufferedDanmaku(0, 1000).single.content, '屏蔽内容');
  });

  test('规则更新后已淘汰的原始段成为缺失，保留段按新规则重算', () async {
    final player = _Player(mergeDanmaku: false);
    final controller = PlDanmakuController(
      1,
      player,
      false,
      rawCache: DanmakuRawCache(maxBytes: 700),
    );
    addTearDown(controller.dispose);
    await controller.handleDanmaku([_dm('屏蔽内容', 100)], segmentIndex: 0);
    await controller.handleDanmaku([_dm('屏蔽内容', 360100)], segmentIndex: 1);
    player.filters = RuleFilter.empty();
    await controller.refreshRules();
    expect(
      controller.readRange(0, 1000000).coverage.single.state,
      DanmakuCoverageState.missing,
    );
    expect(
      controller.peekBufferedDanmaku(360000, 361000).single.content,
      '屏蔽内容',
    );
  });

  test('规则失效先清空缓存，再从原始输入恢复被屏蔽内容', () async {
    final player = _Player();
    final controller = PlDanmakuController(1, player, false);
    addTearDown(controller.dispose);
    final raw = [_dm('屏蔽内容', 100), _dm('保留', 200)];
    await controller.handleDanmaku(raw, segmentIndex: 0);
    expect(controller.peekBufferedDanmaku(0, 1000).map((e) => e.content), [
      '保留',
    ]);
    final events = <DanmakuSourceChange>[];
    final subscription = controller.changes.listen((event) {
      events.add(event);
      if (event.kind == DanmakuSourceChangeKind.invalidated) {
        expect(controller.peekBufferedDanmaku(0, 1000), isEmpty);
        expect(
          controller.readRange(0, 1000000).coverage.single.state,
          DanmakuCoverageState.invalidated,
        );
      }
    });
    addTearDown(subscription.cancel);
    player.filters = RuleFilter.empty();
    final pending = controller.refreshRules();
    expect(events.single.kind, DanmakuSourceChangeKind.invalidated);
    await pending;
    expect(events.map((event) => event.kind), [
      DanmakuSourceChangeKind.invalidated,
      DanmakuSourceChangeKind.ready,
    ]);
    expect(events.last.ruleRevision, events.first.ruleRevision);
    expect(
      controller.readRange(0, 1000000).ruleRevision,
      events.last.ruleRevision,
    );
    expect(controller.peekBufferedDanmaku(0, 1000).map((e) => e.content), [
      '屏蔽内容',
      '保留',
    ]);
    expect(raw.every((element) => element.count == 0), isTrue);
  });

  test('连续规则变化撤销旧合并结果，最新修订单独发布就绪', () async {
    final player = _Player();
    final controller = PlDanmakuController(1, player, false);
    addTearDown(controller.dispose);
    final events = <DanmakuSourceChange>[];
    final subscription = controller.changes.listen(events.add);
    addTearDown(subscription.cancel);
    final old = controller.handleDanmaku([
      _dm('内容', 100),
      _dm('内容', 101),
    ], segmentIndex: 0);
    final first = controller.refreshRules();
    player.filters = RuleFilter(['内容'], [], {});
    final latest = controller.refreshRules();
    await Future.wait([old, first, latest]);
    final ready = events.where(
      (event) => event.kind == DanmakuSourceChangeKind.ready,
    );
    expect(ready, hasLength(1));
    expect(ready.single.ruleRevision, 2);
    expect(controller.peekBufferedDanmaku(0, 1000), isEmpty);
    expect(controller.readRange(0, 1000000).isLoaded, isTrue);
  });

  test('重算途中卸载后不发布就绪也不回写缓存', () async {
    final controller = PlDanmakuController(1, _Player(), false);
    await controller.handleDanmaku([_dm('重复', 100)], segmentIndex: 0);
    final events = <DanmakuSourceChange>[];
    final subscription = controller.changes.listen(events.add);
    final pending = controller.refreshRules();
    controller.dispose();
    await pending;
    expect(events.map((event) => event.kind), [
      DanmakuSourceChangeKind.invalidated,
    ]);
    expect(controller.peekBufferedDanmaku(0, 1000), isEmpty);
    await subscription.cancel();
  });

  test('本地来源重算恢复原始条目并可取消合并', () async {
    final player = _Player();
    final controller = PlDanmakuController(1, player, true);
    addTearDown(controller.dispose);
    await controller.handleDanmaku([_dm('重复', 100), _dm('重复', 101)]);
    expect(controller.peekBufferedDanmaku(0, 1000).single.count, 2);
    player.mergeDanmaku = false;
    await controller.refreshRules();
    expect(controller.peekBufferedDanmaku(0, 1000), hasLength(2));
  });

  test(
    'segment stays pending until processing finishes, then uses cached data',
    () async {
      final adapter = _DmAdapter();
      Request.dio.httpClientAdapter = adapter;
      final controller = _HoldingController();
      addTearDown(controller.dispose);
      final pending = controller.queryDanmaku(0);
      await controller.entered.future;
      await controller.queryDanmaku(0);
      expect(adapter.calls, 1);
      controller.resume.complete();
      await pending;
      await controller.queryDanmaku(0);
      expect(adapter.calls, 1);
      expect(controller.peekBufferedDanmaku(0, 1000).single.count, 2);
    },
  );

  test(
    'background processing filters before merging and caches only its segment',
    () async {
      final controller = PlDanmakuController(1, _Player(), false);
      addTearDown(controller.dispose);
      await controller.handleDanmaku([
        _dm('相同的内容', 100),
        _dm('相同的内容', 101),
        _dm('相同的内容屏蔽', 102),
        _dm('其他内容', 200),
        _dm('下一段', 360000),
      ], segmentIndex: 0);
      final cached = controller.peekBufferedDanmaku(0, 360000).toList();
      expect(cached.map((e) => e.content), ['相同的内容', '其他内容']);
      expect(cached.map((e) => e.count), [2, 1]);
    },
  );

  test('dispose during background merge prevents late cache writes', () async {
    final controller = PlDanmakuController(1, _Player(), false);
    final pending = controller.handleDanmaku([
      _dm('重复', 100),
      _dm('重复', 101),
    ], segmentIndex: 0);
    controller.dispose();
    await pending;
    expect(controller.peekBufferedDanmaku(0, 1000), isEmpty);
  });

  test(
    'background processing merges rating pool duplicates into cache',
    () async {
      final controller = PlDanmakuController(1, _Player(), false);
      addTearDown(controller.dispose);
      await controller.handleDanmaku([
        _dm('5', 26600)..pool = 3,
        _dm('5', 27082)..pool = 3,
        _dm('1', 42600)..pool = 3,
        _dm('5', 42600)..pool = 3,
        _dm('1', 42796)..pool = 3,
      ], segmentIndex: 0);
      final cached = controller.peekBufferedDanmaku(26000, 43000).toList();
      expect(cached.map((e) => e.content), ['5', '1']);
      expect(cached.map((e) => e.count), [3, 2]);
    },
  );

  test(
    'disabled merging retains individual messages and bucket limits',
    () async {
      final controller = PlDanmakuController(
        1,
        _Player(mergeDanmaku: false),
        false,
      );
      addTearDown(controller.dispose);
      await controller.handleDanmaku(
        List.generate(20, (i) => _dm('重复', 100 + i)),
        segmentIndex: 0,
      );
      final cached = controller.peekBufferedDanmaku(100, 200).toList();
      expect(cached, hasLength(12));
      // 未开启合并时保持 protobuf 原始计数，不进行额外处理。
      expect(cached.every((e) => e.count == 0), isTrue);
    },
  );

  test(
    'local file merging retains messages across online segment boundaries',
    () async {
      final controller = PlDanmakuController(1, _Player(), true);
      addTearDown(controller.dispose);
      await controller.handleDanmaku([
        _dm('跨段重复', 359900),
        _dm('跨段重复', 360100),
      ]);
      final cached = controller.peekBufferedDanmaku(359000, 361000).toList();
      expect(cached, hasLength(1));
      expect(cached.single.count, 2);
    },
  );
}

class _RangeTargetController extends PlDanmakuController {
  _RangeTargetController() : super(1, _Player(), false);

  final entered = Completer<void>();
  final resume = Completer<void>();
  final segments = <int>[];

  @override
  Future<void> queryDanmaku(int segmentIndex) async {
    segments.add(segmentIndex);
    if (!entered.isCompleted) {
      entered.complete();
      await resume.future;
    }
  }
}

class _SettingsBox implements Box<dynamic> {
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      key == LocalCacheKey.buvid ? 'danmaku-controller-test' : defaultValue;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HoldingController extends PlDanmakuController {
  _HoldingController() : super(1, _Player(), false);

  final entered = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<void> handleDanmaku(
    List<DanmakuElem> elems, {
    int? segmentIndex,
    DanmakuWorkLease? lease,
  }) async {
    entered.complete();
    await resume.future;
    await super.handleDanmaku(elems, segmentIndex: segmentIndex, lease: lease);
  }
}

class _DmAdapter implements HttpClientAdapter {
  int calls = 0;
  bool fail = false;
  int progress = 100;
  DmSegMobileReply? reply;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (fail) {
      return ResponseBody.fromBytes(
        [],
        200,
        headers: {
          'grpc-status': ['13'],
        },
      );
    }
    final reply =
        this.reply ??
        DmSegMobileReply(
          elems: [_dm('重复', progress), _dm('重复', progress + 1)],
        );
    return ResponseBody.fromBytes(
      GrpcReq.compressProtobuf(reply.writeToBuffer()),
      200,
      headers: {
        'grpc-status': ['0'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FilePlayer extends _Player {
  _FilePlayer(String dir)
    : currentFileSource = FileSource(
        dir: dir,
        isMp4: true,
        hasDashAudio: false,
        typeTag: 'test',
      );
  @override
  final FileSource currentFileSource;
}

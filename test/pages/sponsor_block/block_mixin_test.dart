import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/models/common/sponsor_block/segment_model.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/models/remote/sponsor_block/segment_item.dart';
import 'package:pili_aurora/pages/sponsor_block/block_mixin.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _BlockController controller;

  setUpAll(() => GStorage.setting = MemoryBox<dynamic>());

  setUp(() async {
    await GStorage.setting.clear();
    await GStorage.setting.put(SettingBoxKey.blockToast, false);
    controller = _BlockController();
  });
  tearDown(() async {
    controller.onClose();
    await controller.player.positions.close();
    await controller.player.playing.close();
  });

  final intro = SegmentItemModel(
    category: 'intro',
    segment: [0, 27967],
    uuid: 'fixture',
    videoDuration: 600000,
  );

  test('片段响应早于原生媒体就绪时等待真实进度，保留 109 秒续播位置', () async {
    controller.player.state.playing = true;
    await controller.handleSBData([intro]);
    expect(controller.seeks, isEmpty);

    controller.player.emitPosition(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, isEmpty);

    controller.player.state.duration = const Duration(minutes: 10);
    controller.player.emitPosition(const Duration(seconds: 109));
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, isEmpty);
  });

  test('媒体就绪后的首次进度位于片段内时执行一次跳过', () async {
    controller.player.state.playing = true;
    await controller.handleSBData([intro]);
    expect(controller.seeks, isEmpty);

    controller.player.state.duration = const Duration(minutes: 10);
    controller.player.emitPosition(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, [const Duration(milliseconds: 27967)]);
    controller.player.emitPosition(const Duration(seconds: 6));
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, hasLength(1));
  });

  test('播放中的片段响应立即处理当前位置', () async {
    controller.player.state
      ..playing = true
      ..duration = const Duration(minutes: 10)
      ..position = const Duration(seconds: 5);
    await controller.handleSBData([intro]);
    expect(controller.seeks, [const Duration(milliseconds: 27967)]);
  });

  test('原生时长已知但仍在加载时等待首个可用进度', () async {
    controller.player.state
      ..playing = true
      ..buffering = true
      ..duration = const Duration(minutes: 10);
    await controller.handleSBData([intro]);
    expect(controller.seeks, isEmpty);
    controller.player.state.buffering = false;
    controller.player.emitPosition(const Duration(seconds: 109));
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, isEmpty);
  });

  test('重置后旧媒体的 playing 和 position 事件不触发跳过', () async {
    await controller.handleSBData([intro]);
    controller.resetBlock();
    controller.player.state
      ..playing = true
      ..duration = const Duration(minutes: 10);
    controller.player.playing.add(true);
    controller.player.emitPosition(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, isEmpty);
  });
  SegmentItemModel muted(
    String id,
    double start,
    double end, {
    String category = 'intro',
  }) => SegmentItemModel.fromJson({
    'cid': '1',
    'category': category,
    'actionType': 'mute',
    'segment': [start, end],
    'UUID': id,
    'videoDuration': 600,
  });
  void readyAt(int seconds) {
    controller.player.state
      ..playing = true
      ..duration = const Duration(minutes: 10)
      ..position = Duration(seconds: seconds);
  }

  Future<void> position(int seconds) async {
    controller.player.emitPosition(Duration(seconds: seconds));
    await Future<void>.delayed(Duration.zero);
  }

  test('静音动作不跳转，离开片段解除静音且不改用户音量', () async {
    readyAt(5);
    await controller.handleSBData([muted('mute', 0, 10)]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, isEmpty);
    expect(controller.mutes, [true]);
    controller.player.state.volume = 45;
    await position(10);
    expect(controller.mutes, [true, false]);
    expect(controller.player.state.volume, 45);
  });
  test('重叠静音在最后一个片段结束后解除', () async {
    readyAt(7);
    await controller.handleSBData([muted('a', 0, 10), muted('b', 5, 15)]);
    await Future<void>.delayed(Duration.zero);
    await position(10);
    expect(controller.mutes, [true]);
    await position(15);
    expect(controller.mutes, [true, false]);
  });
  test('拖入静音片段生效，静音一次回看不重复，重置释放静音', () async {
    readyAt(20);
    await controller.handleSBData([muted('a', 0, 10)]);
    await position(5);
    expect(controller.mutes, [true]);
    await position(15);
    await position(5);
    expect(controller.mutes, [true, false]);
    controller.resetBlock();
    await controller.handleSBData([muted('b', 0, 10)]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.mutes, [true, false, true]);
    controller.resetBlock();
    await Future<void>.delayed(Duration.zero);
    expect(controller.mutes, [true, false, true, false]);
  });
  test('新安装惊吓分类按响应自动静音，不能在预加载阶段跳过', () async {
    readyAt(5);
    await controller.handleSBData([
      muted('jump', 0, 10, category: 'jumpscare'),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.getFirstSegment(), isNull);
    expect(controller.seeks, isEmpty);
    expect(controller.mutes, [true]);
  });
  test('未知动作和畸形片段不影响后续合法片段', () async {
    readyAt(5);
    await controller.handleSBData([
      SegmentItemModel(
        category: 'intro',
        actionType: 'future',
        segment: [0, 10000],
        uuid: 'unknown',
        videoDuration: 0,
      ),
      SegmentItemModel(category: 'intro', segment: [0], uuid: 'broken'),
      intro,
    ]);
    expect(controller.seeks, [const Duration(milliseconds: 27967)]);
    expect(controller.segmentProgressList, hasLength(1));
    expect(
      controller.segmentProgressList.first.end,
      closeTo(27967 / 600000, 0.0001),
    );
  });
  test('手动静音片段提供跳过操作，重置移除旧提示', () async {
    await GStorage.setting.put(SettingBoxKey.blockSettings, {'intro': 2});
    readyAt(5);
    await controller.handleSBData([muted('manual', 0, 10)]);
    expect(controller.mutes, isEmpty);
    expect(controller.seeks, isEmpty);
    expect(controller.listData, hasLength(1));
    controller.listData.clear();
    await position(8);
    expect(controller.listData, isEmpty);
    await position(15);
    await position(5);
    expect(controller.listData, hasLength(1));
    controller.resetBlock();
    expect(controller.listData, isEmpty);
  });
  test('整片标记和精彩时刻只展示，不作为自动跳过片段', () async {
    readyAt(5);
    await controller.handleSBData([
      SegmentItemModel(
        category: 'sponsor',
        actionType: 'full',
        segment: [0, 0],
        uuid: 'full',
      ),
      SegmentItemModel(
        category: 'poi_highlight',
        actionType: 'poi',
        segment: [5000, 5000],
        uuid: 'poi',
      ),
    ]);
    expect(controller.seeks, isEmpty);
    expect(controller.mutes, isEmpty);
    expect(controller.getFirstSegment(), isNull);
    expect(controller.segmentProgressList, hasLength(2));
  });
}

class _BlockController extends GetxController with BlockMixin {
  @override
  final blockConfig = _BlockConfig();
  @override
  final _Player player = _Player();
  final seeks = <Duration>[];
  final mutes = <bool>[];
  @override
  Future<void> applyBlockMute(bool muted) async {
    mutes.add(muted);
  }

  @override
  bool get autoPlay => true;
  @override
  bool get preInitPlayer => false;
  @override
  bool get isUgc => true;
  @override
  int get timeLength => 600000;
  @override
  int get currPosInMilliseconds => player.state.position.inMilliseconds;

  @override
  Future<void> seekTo(Duration duration, {required bool isSeek}) {
    seeks.add(duration);
    return Future.value();
  }

  // 跳转决策沿用真实 mixin；测试替换提示和计数上报的外部副作用。
  @override
  Future<void> onSkip(
    SegmentModel item, {
    bool isSkip = true,
    bool isSeek = true,
  }) => seekTo(Duration(milliseconds: item.segment.$2), isSeek: isSeek);
}

class _BlockConfig with BlockConfigMixin {}

class _Player implements Player {
  @override
  final state = PlayerState();
  final positions = StreamController<Duration>.broadcast();
  final playing = StreamController<bool>.broadcast();
  @override
  late final stream = _Streams(positions.stream, playing.stream);

  void emitPosition(Duration value) {
    state.position = value;
    positions.add(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected player operation: ${invocation.memberName}');
}

class _Streams implements PlayerStream {
  _Streams(this.position, this.playing);
  @override
  final Stream<Duration> position;
  @override
  final Stream<bool> playing;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected stream: ${invocation.memberName}');
}

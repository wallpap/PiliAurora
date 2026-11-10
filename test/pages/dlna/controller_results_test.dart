import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:dlna_dart/xmlParser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/dlna/controller.dart';

class _Manager extends DLNAManager {
  _Manager() {
    super.stop();
  }

  DeviceManager? current;
  Completer<DeviceManager>? pendingStart;
  Completer<void>? pendingStop;
  bool failStart = false;
  bool failStop = false;
  int starts = 0;
  int stops = 0;

  @override
  Future<DeviceManager> start({reusePort = false}) async {
    starts++;
    if (failStart) throw StateError('synthetic private-start');
    return current = pendingStart == null
        ? DeviceManager()
        : await pendingStart!.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    current?.devices.close();
    await pendingStop?.future;
    if (failStop) throw StateError('synthetic private-stop');
  }
}

class _Device extends DLNADevice {
  _Device(String name) : super(DeviceInfo(name, '', name, []));

  final calls = <String>[];
  String? fail;
  Completer<String>? setting;
  Completer<String>? playing;
  int releases = 0;

  @override
  void dispose() {
    releases++;
    super.dispose();
  }

  @override
  Future<String> setUrl(
    String url, {
    String title = '',
    PlayType type = VideoMime.any,
  }) async {
    calls.add('setUrl');
    if (fail == 'setUrl') throw StateError('synthetic private-url');
    return await (setting?.future ?? Future.value('accepted'));
  }

  @override
  Future<String> play() async {
    calls.add('play');
    if (fail == 'play') throw StateError('synthetic private-play');
    return await (playing?.future ?? Future.value('accepted'));
  }

  @override
  Future<String> pause() async {
    calls.add('pause');
    if (fail == 'pause') throw StateError('synthetic private-pause');
    return 'accepted';
  }
}

void main() {
  late _Manager manager;
  late DlnaController controller;
  setUp(() {
    manager = _Manager();
    controller = DlnaController(manager: manager);
  });
  tearDown(() => controller.dispose());

  Future<void> tick() => Future<void>.delayed(Duration.zero);

  test('搜索启动或流失败均释放搜索状态，并允许重试', () async {
    manager.failStart = true;
    await controller.search();
    expect(controller.searching, false);
    expect(controller.searchError, isNotNull);
    manager.failStart = false;
    final search = controller.search();
    await tick();
    manager.current!.devices.addError(StateError('synthetic private-stream'));
    await search;
    expect(controller.searching, false);
    expect(controller.searchError, isNot(contains('private')));
    final retry = controller.search();
    await tick();
    await manager.current!.devices.close();
    await retry;
    expect(manager.starts, 3);
    expect(controller.searchError, isNull);
  });

  test('定时停止持有异步完成和失败，finally恢复重试资格', () async {
    controller.dispose();
    manager = _Manager();
    controller = DlnaController(
      manager: manager,
      searchDuration: const Duration(milliseconds: 1),
    );
    manager
      ..pendingStop = Completer<void>()
      ..failStop = true;
    final search = controller.search();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(manager.stops, greaterThan(0));
    expect(controller.searching, true);
    manager.pendingStop!.complete();
    await search;
    expect(controller.searching, false);
    expect(controller.searchError, '设备搜索停止失败，请重试');
    manager.failStop = false;
  });

  test('释放后迟到start再次停止资源，不通知已释放页面', () async {
    manager.pendingStart = Completer<DeviceManager>();
    final search = controller.search();
    final disposed = controller;
    var notifications = 0;
    disposed
      ..addListener(() => notifications++)
      ..dispose();
    await tick();
    final earlyStops = manager.stops;
    final device = _Device('late');
    manager.pendingStart!.complete(
      DeviceManager()..deviceList['late'] = device,
    );
    await search;
    expect(manager.stops, greaterThan(earlyStops));
    expect(manager.current!.devices.isClosed, true);
    expect(notifications, 0);
    expect(device.releases, 1);
    controller = DlnaController(manager: _Manager());
  });

  test('设备快照替换移除失效设备，重新搜索保留已确认设备', () async {
    final a = _Device('A');
    final b = _Device('B');
    final search = controller.search();
    await tick();
    manager.current!.devices.add({'A': a, 'B': b});
    await tick();
    expect(
      (await controller.connect(
        key: 'A',
        url: 'https://example.test/video',
        isCurrent: () => true,
      )).isSuccess,
      true,
    );
    manager.current!.devices.add({'A': a});
    await tick();
    expect(controller.devices.keys, ['A']);
    await manager.current!.devices.close();
    await search;
    final retry = controller.search();
    await tick();
    expect(controller.selectedKey, 'A');
    await manager.current!.devices.close();
    await retry;
  });

  test('setUrl/play失败保留旧设备，重试成功后才暂停旧设备，写入互斥', () async {
    final a = _Device('A');
    final b = _Device('B');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    controller.devices.addAll({'A': a, 'B': b});
    Future<bool> connect(String key) async => (await controller.connect(
      key: key,
      url: 'https://example.test/video',
      isCurrent: () => true,
    )).isSuccess;
    expect(await connect('A'), true);
    for (final action in ['setUrl', 'play']) {
      b.fail = action;
      expect(await connect('B'), false);
      expect(controller.selectedKey, 'A');
      expect(a.calls, ['setUrl', 'play']);
      expect(controller.connecting, false);
    }
    b
      ..fail = null
      ..setting = Completer<String>();
    final pending = connect('B');
    expect(controller.selectedKey, 'A');
    expect(await connect('B'), false);
    b.setting!.complete('accepted');
    expect(await pending, true);
    expect(controller.selectedKey, 'B');
    expect(a.calls.last, 'pause');
  });

  test('旧设备暂停失败不撤销新设备确认，失败正文不外泄', () async {
    final a = _Device('A');
    final b = _Device('B');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    controller.devices.addAll({'A': a, 'B': b});
    await controller.connect(
      key: 'A',
      url: 'https://example.test/video',
      isCurrent: () => true,
    );
    a.fail = 'pause';
    final result = await controller.connect(
      key: 'B',
      url: 'https://example.test/video',
      isCurrent: () => true,
    );
    expect(result.toString(), '新设备已连接，请手动暂停原设备');
    expect((result as Error).cause, isA<StateError>());
    expect(controller.selectedKey, 'B');
    expect(controller.connecting, false);
  });

  test('离页后setUrl不续发play，迟到play不发布选中设备', () async {
    final device = _Device('A')..setting = Completer<String>();
    addTearDown(device.dispose);
    controller.devices['A'] = device;
    var current = true;
    Future<void> connect() async {
      await controller.connect(
        key: 'A',
        url: 'https://example.test/video',
        isCurrent: () => current,
      );
    }

    final pending = connect();
    current = false;
    device.setting!.complete('accepted');
    await pending;
    expect(device.calls, ['setUrl']);
    expect(controller.selectedKey, isNull);
    current = true;
    device
      ..setting = null
      ..playing = Completer<String>();
    final retry = connect();
    await tick();
    current = false;
    device.playing!.complete('accepted');
    await retry;
    expect(controller.selectedKey, isNull);
    expect(controller.connecting, false);
  });
}

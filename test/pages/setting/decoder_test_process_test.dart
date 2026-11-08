import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/pages/setting/decoder_test_process.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

VideoItem sample() => VideoItem(
  id: 80,
  codecid: 12,
  quality: VideoQuality.high1080,
  baseUrl: 'https://example.test/private-sample',
);

class _Process implements Process {
  final exited = Completer<int>();
  int kills = 0;
  bool exitOnKill = true;
  @override
  Future<int> get exitCode => exited.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (exitOnKill && !exited.isCompleted) exited.complete(-1);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<WebSocket> connect(Map<String, String> environment, {String? token}) =>
    WebSocket.connect(
      'ws://127.0.0.1:${environment['PILIAURORA_DECODER_TEST_PORT']}',
      headers: {
        HttpHeaders.authorizationHeader:
            token ?? environment['PILIAURORA_DECODER_TEST_TOKEN']!,
      },
    );

const success = {
  'passed': true,
  'cancelled': false,
  'fallback': false,
  'decoder': 'DirectX 11',
  'size': '1920x1080',
  'speed': 1.0,
  'cpu': 2.5,
  'memory': 150.0,
};

void main() {
  setUpAll(() => GStorage.setting = MemoryBox<dynamic>());

  test('Windows 的所有测试模式使用进程隔离，包括 Vulkan', () async {
    for (final decoder in HwDecType.values) {
      final session = createDecoderTestSession(decoder, sample());
      expect(session, isA<ProcessDecoderTestSession>());
      await session.dispose();
    }
  }, skip: !Platform.isWindows);

  test('驱动访问违规只报告当前测试失败，下一组仍可正常完成', () async {
    final crashed = _Process()..exited.complete(-1073741819);
    final first = ProcessDecoderTestSession(
      HwDecType.vulkanCopy,
      sample(),
      launch: (_) async => crashed,
    );
    final failed = await first.run();
    expect(failed.passed, isFalse);
    expect(failed.error, contains('0xc0000005'));
    await first.dispose();

    final next = _Process();
    final second = ProcessDecoderTestSession(
      HwDecType.d3d11va,
      sample(),
      launch: (environment) async {
        final socket = await connect(environment);
        final input = jsonDecode(await socket.first as String) as Map;
        expect(input['decoder'], 'd3d11va');
        expect(input['url'], sample().baseUrl);
        expect(input.keys, isNot(contains('accounts')));
        socket.add(jsonEncode(success));
        await socket.close();
        next.exited.complete(0);
        return next;
      },
    );
    final passed = await second.run();
    expect(passed.passed, isTrue);
    expect(passed.performance?.averageCpu, 2.5);
    expect(passed.performance?.peakMemoryMb, 150);
  });

  test('缺少本轮凭证的本地连接不能读取样片地址', () async {
    final process = _Process();
    final session = ProcessDecoderTestSession(
      HwDecType.no,
      sample(),
      launch: (environment) async {
        await expectLater(
          connect(environment, token: 'invalid'),
          throwsA(isA<WebSocketException>()),
        );
        final socket = await connect(environment);
        await socket.first;
        socket.add(jsonEncode(success));
        await socket.close();
        process.exited.complete(0);
        return process;
      },
    );
    expect((await session.run()).passed, isTrue);
  });

  test('即使已收到成功结果，异常退出仍判定失败', () async {
    final process = _Process();
    final session = ProcessDecoderTestSession(
      HwDecType.no,
      sample(),
      launch: (environment) async {
        final socket = await connect(environment);
        await socket.first;
        socket.add(jsonEncode(success));
        await socket.close();
        process.exited.complete(-1073741819);
        return process;
      },
    );
    expect((await session.run()).passed, isFalse);
  });

  test('停止期间等待迟到的进程启动并确认退出，不能留下孤儿进程', () async {
    final launching = Completer<void>();
    final started = Completer<Process>();
    final process = _Process()..exitOnKill = false;
    final session = ProcessDecoderTestSession(
      HwDecType.vulkanCopy,
      sample(),
      launch: (_) {
        launching.complete();
        return started.future;
      },
    );
    final running = session.run();
    await launching.future;
    var released = false;
    final stopping = session.dispose().then((_) => released = true);
    started.complete(process);
    await Future<void>.delayed(Duration.zero);
    expect(process.kills, greaterThan(0));
    expect(released, isFalse);
    process.exited.complete(-1);
    await stopping;
    expect((await running).cancelled, isTrue);
  });

  test('超时结束挂住的测试进程，等待退出后返回失败', () async {
    final process = _Process();
    final session = ProcessDecoderTestSession(
      HwDecType.vulkanCopy,
      sample(),
      budget: const Duration(milliseconds: 100),
      launch: (_) async => process,
    );
    final result = await session.run();
    expect(result.error, '测试进程超时');
    expect(process.kills, greaterThan(0));
    expect(process.exited.isCompleted, isTrue);
  });
}

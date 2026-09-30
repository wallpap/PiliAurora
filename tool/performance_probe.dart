// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';

// 合成数据探针，不联网、不读取账号或媒体文件。用 dart run 执行。
Future<void> main() async {
  print('case,items,rawBytes,gzipBytes,medianMs,maxMs,maxTimerGapMs');
  for (final count in [3000, 30000, 100000]) {
    final message = DmSegMobileReply(
      elems: List.generate(
        count,
        (i) => DanmakuElem(
          progress: i * 3 % 360000,
          content: '这是重复出现的弹幕 ${i % 100}',
          midHash: 'user${i % 1000}',
          mode: 1,
          fontsize: 25,
          color: 0xffffff,
          weight: 6,
        ),
      ),
    );
    final raw = message.writeToBuffer();
    final compressed = const GZipEncoder().encodeBytes(raw);
    await _measure(
      'protobuf+gzip sync',
      count,
      raw.length,
      compressed.length,
      () {
        return DmSegMobileReply.fromBuffer(
          const GZipDecoder().decodeBytes(compressed),
        ).elems.length;
      },
    );
    await _measure(
      'protobuf+gzip isolate',
      count,
      raw.length,
      compressed.length,
      () async => (await Isolate.run(
        () => DmSegMobileReply.fromBuffer(
          const GZipDecoder().decodeBytes(compressed),
        ),
      )).elems.length,
    );
    final jsonBytes = utf8.encode(
      jsonEncode({
        'items': List.generate(
          count,
          (i) => {
            'id': i,
            'title': '合成视频标题 $i',
            'owner': {'mid': i % 1000, 'name': '合成用户'},
          },
        ),
      }),
    );
    final jsonGzip = const GZipEncoder().encodeBytes(jsonBytes);
    await _measure(
      'gzip+UTF8 sync',
      count,
      jsonBytes.length,
      jsonGzip.length,
      () => utf8.decode(const GZipDecoder().decodeBytes(jsonGzip)).length,
    );
    await _measure(
      'UTF8+JSON sync',
      count,
      jsonBytes.length,
      jsonGzip.length,
      () => (jsonDecode(utf8.decode(jsonBytes)) as Map)['items'].length,
    );
  }
}

Future<void> _measure(
  String name,
  int count,
  int raw,
  int compressed,
  FutureOr<int> Function() action,
) async {
  for (var i = 0; i < 3; i++) {
    await action();
  }
  final samples = <double>[];
  var maxTimerGap = 0.0;
  for (var i = 0; i < 10; i++) {
    final heartbeat = Stopwatch()..start();
    var previousTick = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final now = heartbeat.elapsedMicroseconds;
      final gap = (now - previousTick) / 1000;
      if (gap > maxTimerGap) maxTimerGap = gap;
      previousTick = now;
    });
    final watch = Stopwatch()..start();
    try {
      final result = await action();
      watch.stop();
      if (result <= 0) throw StateError('探针没有返回数据');
      samples.add(watch.elapsedMicroseconds / 1000);
      // 让同步计算结束后的第一个定时器触发，记录事件循环被阻塞的时间。
      await Future<void>.delayed(const Duration(milliseconds: 2));
    } finally {
      timer.cancel();
    }
  }
  samples.sort();
  final median = (samples[4] + samples[5]) / 2;
  print(
    '$name,$count,$raw,$compressed,${median.toStringAsFixed(3)},'
    '${samples.last.toStringAsFixed(3)},${maxTimerGap.toStringAsFixed(3)}',
  );
}

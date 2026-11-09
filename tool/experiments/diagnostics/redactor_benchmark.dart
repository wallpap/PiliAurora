import 'dart:convert';
import 'dart:io';

import 'package:pili_aurora/services/diagnostics/redact.dart';

void main(List<String> paths) {
  const plain = [
    '[ffmpeg] format: video/mp4 h264 yuv420p 1920x1080 60 fps',
    'position=1295.50 duration=1302.15 paused=false cache=17.2 MiB',
    'Dart layer visible=true frameReady=false epoch=1234',
    'GPU ready? paused=true',
  ];
  _measure('plain-20000', () {
    var length = 0;
    for (var i = 0; i < 20000; i++) {
      length += DiagnosticRedactor.text(plain[i % plain.length]).length;
    }
    return length;
  });
  const signed =
      'GET https://user:pass@example.test:8443/chunk.m4s?'
      'e=123&mid=synthetic-user&upsig=synthetic-signature#fragment';
  _measure('urls-5000', () {
    var length = 0;
    for (var i = 0; i < 5000; i++) {
      length += DiagnosticRedactor.text(signed).length;
    }
    return length;
  });
  final longWord = 'x' * 65000;
  _measure('long-word-100', () {
    var length = 0;
    for (var i = 0; i < 100; i++) {
      length += DiagnosticRedactor.text(longWord, maxLength: 65536).length;
    }
    return length;
  });
  for (final size in [4096, 8192, 16384]) {
    final word = 'a-' * (size ~/ 2);
    _measure(
      'hyphens-$size',
      () => DiagnosticRedactor.text(word, maxLength: 65536).length,
    );
  }
  final buvidNoise = '${'buvid' * 2048} ordinary=value';
  _measure(
    'buvid-noise-10240',
    () => DiagnosticRedactor.text(buvidNoise, maxLength: 65536).length,
  );
  final records = <Object?>[];
  var skipped = 0;
  // 只读本地文件，输出条数、长度和耗时，不回显任何日志内容。
  for (final path in paths) {
    for (final line in File(path).readAsLinesSync()) {
      try {
        records.add(jsonDecode(line));
      } on FormatException {
        skipped++;
      }
    }
  }
  if (paths.isNotEmpty) {
    stdout.writeln(jsonEncode({'records': records.length, 'skipped': skipped}));
    _measure('archive-redaction', () {
      var length = 0;
      for (final record in records) {
        // 与归档导出使用同一分类及预算，解码和文件读取不计入脱敏耗时。
        final cleaned =
            record is Map &&
                (record.containsKey('channel') || record['type'] == 'sample')
            ? DiagnosticRedactor.exportRecord(Map<String, Object?>.from(record))
            : DiagnosticRedactor.clean(record);
        length += jsonEncode(cleaned).length;
      }
      return length;
    });
  }
}

void _measure(String name, int Function() action) {
  var outputCharacters = 0;
  for (var i = 0; i < 3; i++) {
    outputCharacters = action();
  }
  final samples = <int>[];
  for (var i = 0; i < 7; i++) {
    final watch = Stopwatch()..start();
    outputCharacters = action();
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  stdout.writeln(
    jsonEncode({
      'case': name,
      'medianUs': samples[3],
      'outputCharacters': outputCharacters,
    }),
  );
}

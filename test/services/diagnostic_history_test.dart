import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/history_reader.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pili-history-test-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<_CountingFile> logFile(String name, Iterable<String> lines) async {
    final file = File('${directory.path}/$name');
    await file.writeAsString('${lines.join('\n')}\n');
    return _CountingFile(file);
  }

  Iterable<String> records(int start, int count) => Iterable.generate(
    count,
    (index) => jsonEncode({'index': start + index, 'message': '合成日志'}),
  );

  test('does not read older files after recovering 200 current records', () async {
    final current = await logFile('runtime.jsonl', records(600, 600));
    final previous = await logFile('runtime.jsonl.1', records(0, 600));

    final history = await readDiagnosticHistory([current, previous]);

    expect(history.map((record) => record['index']), orderedEquals(
      Iterable.generate(200, (index) => 1000 + index),
    ));
    expect(current.reads, 1);
    expect(previous.reads, 0, reason: '最新文件已足够，不应扫描即将被丢弃的历史。');
  });

  test('fills from rotated files and returns oldest to newest', () async {
    final current = await logFile('runtime.jsonl', [
      ...records(250, 50),
      'incomplete record',
      '[]',
      'null',
    ]);
    final previous = await logFile('runtime.jsonl.1', records(100, 150));
    final oldest = await logFile('runtime.jsonl.2', records(0, 100));

    final history = await readDiagnosticHistory([current, previous, oldest]);

    expect(history.map((record) => record['index']), orderedEquals(
      Iterable.generate(200, (index) => 100 + index),
    ));
    expect(current.reads, 1);
    expect(previous.reads, 1);
    expect(oldest.reads, 0);
  });

  test('skips invalid recent lines without losing valid older records', () async {
    final current = await logFile('runtime.jsonl', [
      ...records(0, 201),
      for (var index = 0; index < 210; index++) 'broken-$index',
    ]);

    final history = await readDiagnosticHistory([current]);

    expect(history.map((record) => record['index']), orderedEquals(
      Iterable.generate(200, (index) => 1 + index),
    ));
  });

  test('keeps a bounded tail and ignores its incomplete leading line', () async {
    final current = await logFile('runtime.jsonl', [
      jsonEncode({'message': 'x' * 300000}),
      ...records(0, 30),
    ]);

    final history = await readDiagnosticHistory([current]);

    expect(history.map((record) => record['index']), orderedEquals(
      Iterable.generate(30),
    ));
    expect(current.bytesRead, lessThanOrEqualTo(262144));
  });

  test('accepts CRLF, a missing trailing newline and malformed UTF-8', () async {
    final file = File('${directory.path}/runtime.jsonl');
    await file.writeAsBytes([
      ...utf8.encode('{"index":0}\r\n'),
      0xff,
      0x0a,
      ...utf8.encode('{"index":1}'),
    ]);

    final history = await readDiagnosticHistory([_CountingFile(file)]);

    expect(history.map((record) => record['index']), orderedEquals([0, 1]));
  });

  test('historical records still pass through bounded redaction', () async {
    final current = await logFile('runtime.jsonl', [
      jsonEncode({'index': 0, 'message': 'x' * 6000}),
    ]);

    final history = await readDiagnosticHistory([current]);

    expect((history.single['message'] as String).length, lessThan(6000));
  });

  test('handles empty files and an empty file list', () async {
    final current = await logFile('runtime.jsonl', []);

    expect(await readDiagnosticHistory([current]), isEmpty);
    expect(await readDiagnosticHistory([]), isEmpty);
  });
}

class _CountingFile implements File {
  _CountingFile(this.source);

  final File source;
  int reads = 0;
  int bytesRead = 0;

  @override
  int lengthSync() => source.lengthSync();

  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    reads++;
    return source.openRead(start, end).map((bytes) {
      bytesRead += bytes.length;
      return bytes;
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected file operation: ${invocation.memberName}');
}
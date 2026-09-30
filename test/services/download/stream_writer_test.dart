import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/download/stream_writer.dart';

class _SlowConsumer implements StreamConsumer<List<int>> {
  final firstWrite = Completer<void>();
  final release = Completer<void>();
  final bytes = <int>[];

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      if (!firstWrite.isCompleted) firstWrite.complete();
      await release.future;
      bytes.addAll(chunk);
    }
  }

  @override
  Future<void> close() async {}
}

void main() {
  test(
    'slow writes bound source reads and preserve bytes and progress',
    () async {
      var produced = 0;
      Stream<List<int>> source() async* {
        for (var i = 0; i < 10000; i++) {
          produced++;
          yield [i % 256];
        }
      }

      final consumer = _SlowConsumer();
      final progress = <int>[];
      final task = writeDownloadStream(
        source(),
        consumer,
        initialBytes: 7,
        onProgress: progress.add,
      );
      await consumer.firstWrite.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(produced, lessThanOrEqualTo(2));
      consumer.release.complete();
      expect(await task, 10007);
      expect(consumer.bytes, List.generate(10000, (i) => i % 256));
      expect(progress.first, 8);
      expect(progress.last, 10007);
    },
  );

  test('source errors propagate after already written bytes', () async {
    final consumer = _SlowConsumer()..release.complete();
    Stream<List<int>> source() async* {
      yield [1, 2, 3];
      throw StateError('network failed');
    }

    await expectLater(
      writeDownloadStream(source(), consumer),
      throwsStateError,
    );
    expect(consumer.bytes, [1, 2, 3]);
  });

  test('write failures propagate to the download task', () async {
    await expectLater(
      writeDownloadStream(Stream.value([1, 2]), _FailedConsumer()),
      throwsStateError,
    );
  });
}

class _FailedConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final _ in stream) {
      throw StateError('disk failed');
    }
  }

  @override
  Future<void> close() async {}
}

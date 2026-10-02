import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/download/response_adapter.dart';
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

Dio _client(HttpClientAdapter adapter, {Duration? receiveTimeout}) {
  final client = Dio(
    BaseOptions(
      receiveTimeout: receiveTimeout ?? const Duration(milliseconds: 50),
    ),
  )..httpClientAdapter = DownloadResponseAdapter(adapter);
  addTearDown(() => client.close(force: true));
  return client;
}

Future<Response<ResponseBody>> _response(
  Dio client, {
  CancelToken? cancelToken,
  bool pauseAware = true,
}) => client.get<ResponseBody>(
  'https://example.test/video',
  options: Options(
    responseType: ResponseType.stream,
    extra: {DownloadResponseAdapter.pauseAwareTimeoutKey: pauseAware},
  ),
  cancelToken: cancelToken,
);

Matcher get _receiveTimeoutError => isA<DioException>().having(
  (error) => error.type,
  'type',
  DioExceptionType.receiveTimeout,
);

void main() {
  test('paused download consumers do not trigger receive timeout', () async {
    final adapter = _ResponseAdapter();
    final client = _client(adapter);
    final response = await _response(client);
    final consumer = _SlowConsumer();
    final task = writeDownloadStream(response.data!.stream, consumer);
    adapter.source.add(Uint8List.fromList([1]));
    await consumer.firstWrite.future;
    await Future<void>.delayed(Duration.zero);
    adapter.source.add(Uint8List.fromList([2, 3]));
    final closed = adapter.source.close();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    consumer.release.complete();
    expect(await task, 3);
    expect(consumer.bytes, [1, 2, 3]);
    expect(client.options.receiveTimeout, const Duration(milliseconds: 50));
    expect(adapter.receiveTimeoutAtFetch, const Duration(milliseconds: 50));
    await closed;
  });

  test(
    'active download reception still times out on a stalled source',
    () async {
      final adapter = _ResponseAdapter();
      final response = await _response(_client(adapter));
      final consumer = _SlowConsumer()..release.complete();
      final task = writeDownloadStream(response.data!.stream, consumer);
      adapter.source.add(Uint8List.fromList([1]));
      await expectLater(task, throwsA(_receiveTimeoutError));
      expect(consumer.bytes, [1]);
      expect(adapter.sourceCancelled, isTrue);
    },
  );

  test('download reception times out before the first body chunk', () async {
    final adapter = _ResponseAdapter();
    final response = await _response(_client(adapter));
    final consumer = _SlowConsumer()..release.complete();
    await expectLater(
      writeDownloadStream(response.data!.stream, consumer),
      throwsA(_receiveTimeoutError),
    );
    expect(consumer.bytes, isEmpty);
    expect(adapter.sourceCancelled, isTrue);
  });

  test(
    'cancellation releases a download source while the writer is paused',
    () async {
      final adapter = _ResponseAdapter();
      final cancelToken = CancelToken();
      final response = await _response(
        _client(adapter),
        cancelToken: cancelToken,
      );
      final consumer = _SlowConsumer();
      final task = writeDownloadStream(response.data!.stream, consumer);
      adapter.source.add(Uint8List.fromList([1]));
      await consumer.firstWrite.future;
      cancelToken.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(adapter.sourceCancelled, isTrue);
      consumer.release.complete();
      await expectLater(
        task,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
    },
  );

  test(
    'unmarked response streams retain their existing timeout behavior',
    () async {
      final adapter = _ResponseAdapter();
      final response = await _response(_client(adapter), pauseAware: false);
      final consumer = _SlowConsumer();
      final task = writeDownloadStream(response.data!.stream, consumer);
      adapter.source.add(Uint8List.fromList([1]));
      await consumer.firstWrite.future;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      consumer.release.complete();
      await expectLater(task, throwsA(_receiveTimeoutError));
      expect(adapter.sourceCancelled, isTrue);
    },
  );

  test('zero receive timeout remains disabled for downloads', () async {
    final adapter = _ResponseAdapter();
    final response = await _response(
      _client(adapter, receiveTimeout: Duration.zero),
    );
    final consumer = _SlowConsumer();
    final task = writeDownloadStream(response.data!.stream, consumer);
    adapter.source.add(Uint8List.fromList([1]));
    await consumer.firstWrite.future;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final closed = adapter.source.close();
    consumer.release.complete();
    expect(await task, 1);
    await closed;
  });

  test(
    'download requests retain the HTTP adapter response header timeout',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final accepted = Completer<void>();
      server.listen((request) => accepted.complete());
      final client = _client(
        IOHttpClientAdapter(),
        receiveTimeout: const Duration(milliseconds: 150),
      );
      final request = client.get<ResponseBody>(
        'http://127.0.0.1:${server.port}/video',
        options: Options(
          responseType: ResponseType.stream,
          extra: {DownloadResponseAdapter.pauseAwareTimeoutKey: true},
        ),
      );
      final failure = expectLater(request, throwsA(_receiveTimeoutError));
      await accepted.future.timeout(const Duration(seconds: 5));
      await failure;
    },
  );

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

class _ResponseAdapter implements HttpClientAdapter {
  final source = StreamController<Uint8List>();
  bool sourceCancelled = false;
  Duration? receiveTimeoutAtFetch;

  _ResponseAdapter() {
    source.onCancel = () => sourceCancelled = true;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    receiveTimeoutAtFetch = options.receiveTimeout;
    return ResponseBody(source.stream, 200);
  }

  @override
  void close({bool force = false}) {
    source.close();
  }
}

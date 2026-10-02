import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models_new/download/bili_download_entry_info.dart';
import 'package:pili_aurora/services/download/download_manager.dart';
import 'package:pili_aurora/services/download/response_adapter.dart';

void main() {
  late Directory directory;
  late Dio client;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pili-download-test-');
    client = Dio();
  });
  tearDown(() async {
    client.close(force: true);
    await directory.delete(recursive: true);
  });

  test('download completes and resumes without corrupting bytes', () async {
    final bytes = List.generate(8192, (i) => i % 256);
    final adapter = _Adapter((options) async {
      final start = int.parse(
        options.headers['range'].toString().split('=')[1].split('-')[0],
      );
      return ResponseBody(
        Stream.value(Uint8List.fromList(bytes.sublist(start))),
        start == 0 ? 200 : 206,
        headers: {
          'content-length': ['${bytes.length - start}'],
        },
      );
    });
    client.httpClientAdapter = adapter;
    final file = File('${directory.path}/video.bin');
    await file.writeAsBytes(bytes.take(100).toList());
    var completed = 0;
    final manager = DownloadManager(
      url: 'https://example.test/video',
      path: file.path,
      client: client,
      onReceiveProgress: null,
      onDone: ([error]) {
        expect(error, isNull);
        completed++;
      },
    );
    await manager.task;
    expect(manager.status, DownloadStatus.completed);
    expect(completed, 1);
    expect(await file.readAsBytes(), bytes);
    expect(adapter.lastRequest!.headers['range'], 'bytes=100-');
  });

  test('stream error keeps partial data and reports failure once', () async {
    Stream<Uint8List> source() async* {
      yield Uint8List.fromList([1, 2, 3]);
      throw const FileSystemException('stream failed');
    }

    client.httpClientAdapter = _Adapter(
      (_) async => ResponseBody(source(), 200),
    );
    final errors = <Object?>[];
    final file = File('${directory.path}/partial.bin');
    final manager = DownloadManager(
      url: 'https://example.test/video',
      path: file.path,
      client: client,
      onReceiveProgress: null,
      onDone: ([error]) => errors.add(error),
    );
    await manager.task;
    expect(manager.status, DownloadStatus.failDownload);
    expect(errors, hasLength(1));
    expect(errors.single, isNotNull);
    expect(await file.readAsBytes(), [1, 2, 3]);
  });

  test(
    'network idle timeout keeps partial bytes and reports failure once',
    () async {
      final source = StreamController<Uint8List>();
      var cancelled = false;
      source.onCancel = () => cancelled = true;
      client.options.receiveTimeout = const Duration(milliseconds: 100);
      client.httpClientAdapter = DownloadResponseAdapter(
        _Adapter((_) async {
          scheduleMicrotask(() => source.add(Uint8List.fromList([1, 2, 3])));
          return ResponseBody(source.stream, 200);
        }),
      );
      final errors = <Object?>[];
      final file = File('${directory.path}/timed-out.bin');
      final manager = DownloadManager(
        url: 'https://example.test/video',
        path: file.path,
        client: client,
        onReceiveProgress: null,
        onDone: ([error]) => errors.add(error),
      );
      await manager.task;
      expect(manager.status, DownloadStatus.failDownload);
      expect(errors, hasLength(1));
      expect(
        errors.single,
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      );
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(cancelled, isTrue);
      await source.close();
    },
  );

  test('write pipeline failures cancel the network response', () async {
    final source = StreamController<Uint8List>();
    var cancelled = false;
    source.onCancel = () => cancelled = true;
    client.options.receiveTimeout = const Duration(seconds: 10);
    client.httpClientAdapter = DownloadResponseAdapter(
      _Adapter((_) async {
        scheduleMicrotask(() => source.add(Uint8List.fromList([1, 2, 3])));
        return ResponseBody(source.stream, 200);
      }),
    );
    const writeError = FileSystemException('write pipeline failed');
    final errors = <Object?>[];
    final manager = DownloadManager(
      url: 'https://example.test/video',
      path: '${directory.path}/write-failure.bin',
      client: client,
      onReceiveProgress: (received, _) {
        if (received > 0) throw writeError;
      },
      onDone: ([error]) => errors.add(error),
    );
    addTearDown(() async {
      await manager.cancel(isDelete: true);
      await source.close();
    });
    await manager.task;
    expect(manager.status, DownloadStatus.failDownload);
    expect(errors, [writeError]);
    expect(cancelled, isTrue);
  });

  test(
    'pause cancels an active response and preserves downloaded bytes',
    () async {
      final firstChunk = Completer<void>();
      final stream = StreamController<Uint8List>();
      client.httpClientAdapter = _Adapter((_) async {
        scheduleMicrotask(() => stream.add(Uint8List.fromList([4, 5, 6])));
        return ResponseBody(
          stream.stream,
          200,
          headers: {
            'content-length': ['9'],
          },
        );
      });
      final errors = <Object?>[];
      final file = File('${directory.path}/paused.bin');
      final manager = DownloadManager(
        url: 'https://example.test/video',
        path: file.path,
        client: client,
        onReceiveProgress: (received, _) {
          if (received > 0 && !firstChunk.isCompleted) firstChunk.complete();
        },
        onDone: ([error]) => errors.add(error),
      );
      await firstChunk.future;
      await manager.cancel(isDelete: false);
      await stream.close();
      expect(manager.status, DownloadStatus.pause);
      expect(errors, hasLength(1));
      expect(errors.single, isNotNull);
      expect(await file.readAsBytes(), [4, 5, 6]);
    },
  );
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  RequestOptions? lastRequest;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    lastRequest = options;
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

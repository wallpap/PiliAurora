import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/pages/about/diagnostics_page.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/http_diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/player_diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';
import 'package:pili_aurora/services/diagnostics/record_store.dart';
import 'package:pili_aurora/services/diagnostics/redact.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Diagnostics diagnostics;
  var reads = 0;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pili-diagnostics-test-');
    reads = 0;
    diagnostics = Diagnostics(
      processReader: () {
        reads++;
        return {'rssBytes': 123456, 'privateBytes': null};
      },
    );
    await diagnostics.initialize(directory: directory);
  });
  tearDown(() async {
    diagnostics.dispose();
    await diagnostics.flush();
    await directory.delete(recursive: true);
  });

  test('disposed players never enter native property reads', () {
    expect(readMpvProperty(_DisposedNativePlayer(), 'hwdec-current'), isNull);
  });

  test('redacts credentials in maps, headers, URLs and quoted text', () {
    final output = jsonEncode(
      DiagnosticRedactor.clean({
        'Cookie': 'session-cookie-test',
        'accessToken': 'token-test-value',
        'message': 'Cookie: first=cookie-test-one; other=cookie-test-two\nAuthorization: Bearer auth-test-value\n{"password": "password-test-value"}\nhttps://user:pwd@host/path?sign=query-test-value',
        'path': r'C:\Users\SensitiveUser\private\file.txt',
        'key': '-----BEGIN PRIVATE KEY-----\nprivate-key-test-value\n-----END PRIVATE KEY-----',
        'credentials': 'apiKey=api-key-test-value\npasswd=passwd-test-value',
        'unixPath': '/home/PrivateUser/file',
      }),
    );
    for (final value in [
      'session-cookie-test',
      'token-test-value',
      'cookie-test-one',
      'cookie-test-two',
      'auth-test-value',
      'password-test-value',
      'query-test-value',
      'SensitiveUser',
      'user:pwd',
      'private-key-test-value',
      'api-key-test-value',
      'passwd-test-value',
      'PrivateUser',
    ]) {
      expect(output, isNot(contains(value)));
    }
    expect(output, contains('https://host/path'));
  });

  test('nested diagnostic payloads remain bounded', () {
    final large = List.generate(64, (_) => List.filled(64, 'x' * 10000));
    expect(jsonEncode(DiagnosticRedactor.clean(large)).length, lessThan(65536));
  });

  test('levels change immediately and recent logs stay bounded', () async {
    diagnostics.log(DiagnosticLogLevel.debug, 'test', 'hidden');
    expect(diagnostics.recentLogs, isEmpty);
    await diagnostics.configure(level: DiagnosticLogLevel.debug);
    for (var i = 0; i < 250; i++) {
      diagnostics.log(DiagnosticLogLevel.debug, 'test', 'record $i');
    }
    expect(diagnostics.recentLogs, hasLength(200));
    expect(diagnostics.recentLogs.first['message'], 'record 249');
    await diagnostics.configure(level: DiagnosticLogLevel.off);
    diagnostics.log(DiagnosticLogLevel.error, 'test', 'hidden error');
    expect(diagnostics.recentLogs.first['message'], 'record 249');
  });

  test(
    'tracking is opt in and snapshots include current module data',
    () async {
      diagnostics.capture();
      expect(reads, 0);
      final detach = diagnostics.register(
        'player',
        () => {'width': 1920, 'buffering': true},
      );
      await diagnostics.configure(tracing: true, intervalMs: 250);
      diagnostics.begin('http', 'GET')!
        ..finish()
        ..finish();
      diagnostics.capture();
      expect(diagnostics.latest!['process'], containsPair('rssBytes', 123456));
      expect(
        (diagnostics.latest!['operations'] as Map)['http'],
        containsPair('completed', 1),
      );
      expect(
        (diagnostics.latest!['sources'] as Map)['player'],
        containsPair('width', 1920),
      );
      detach();
      diagnostics.capture();
      expect(diagnostics.latest!['sources'], isEmpty);
      await diagnostics.configure(tracing: false);
      final stoppedReads = reads;
      diagnostics.capture();
      expect(reads, stoppedReads);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(reads, stoppedReads);
    },
  );

  test(
    'settings and bounded history survive a restart, then can be cleared',
    () async {
      Map<String, Object?> settings = {};
      final first = Diagnostics(processReader: () => {});
      await first.initialize(
        directory: directory,
        saveSettings: (value) async => settings = value,
      );
      await first.configure(
        tracing: true,
        level: DiagnosticLogLevel.debug,
        intervalMs: 250,
      );
      for (var i = 0; i < 205; i++) {
        first.log(DiagnosticLogLevel.info, 'test', 'history $i');
      }
      first.dispose();
      await first.flush();
      await File('${directory.path}/runtime.jsonl').writeAsString(
        'incomplete record\n',
        mode: FileMode.append,
      );
      final restored = Diagnostics(processReader: () => {});
      try {
        await restored.initialize(
          directory: directory,
          level: DiagnosticLogLevel.parse(settings['level'] as String),
          tracing: settings['tracing'] as bool,
          intervalMs: settings['intervalMs'] as int,
        );
        expect(restored.level, DiagnosticLogLevel.debug);
        expect(restored.tracing, isTrue);
        expect(restored.intervalMs, 250);
        expect(restored.recentLogs, hasLength(200));
        expect(restored.recentLogs.first['message'], 'history 204');
        expect(restored.recentLogs.last['message'], 'history 5');
        await restored.clear();
        expect(restored.tracing, isFalse);
        expect(restored.recentLogs, isEmpty);
        expect(await restored.files(), isEmpty);
        restored.log(DiagnosticLogLevel.error, 'test', 'after clear');
        await restored.flush();
        expect(await restored.files(), hasLength(1));
      } finally {
        restored.dispose();
        await restored.flush();
      }
    },
  );

  test('HTTP success and failure finish operations without copying request secrets', () async {
    await diagnostics.configure(tracing: true, level: DiagnosticLogLevel.debug);
    final dio = Dio()..httpClientAdapter = _TestHttpAdapter();
    dio.interceptors.add(DiagnosticHttpInterceptor(diagnostics: diagnostics));
    try {
      await dio.post<Object?>(
        'https://example.test/success?token=http-query-test',
        data: {'password': 'http-body-test'},
        options: Options(headers: {'Cookie': 'http-cookie-test'}),
      );
      await expectLater(
        dio.get<Object?>('https://example.test/failure'),
        throwsA(isA<DioException>()),
      );
      diagnostics.capture();
      final http = (diagnostics.latest!['operations'] as Map)['http'] as Map;
      expect(http['active'], 0);
      expect(http['completed'], 2);
      expect(http['errors'], 1);
      expect(diagnostics.recentLogs, hasLength(2));
      final records = jsonEncode(diagnostics.recentLogs);
      for (final secret in [
        'http-query-test',
        'http-body-test',
        'http-cookie-test',
      ]) {
        expect(records, isNot(contains(secret)));
      }
      await diagnostics.configure(level: DiagnosticLogLevel.error);
      await expectLater(
        dio.get<Object?>('https://example.test/failure'),
        throwsA(isA<DioException>()),
      );
      expect(diagnostics.recentLogs, hasLength(3));
    } finally {
      dio.close(force: true);
    }
  });

  test('HTTP retries do not leave an active operation behind', () async {
    await diagnostics.configure(tracing: true);
    final interceptor = DiagnosticHttpInterceptor(diagnostics: diagnostics);
    final options = RequestOptions(path: 'https://example.test/retry');
    interceptor
      ..onRequest(options, RequestInterceptorHandler())
      ..onRequest(options, RequestInterceptorHandler())
      ..onResponse(
        Response<Object?>(requestOptions: options, statusCode: 200),
        ResponseInterceptorHandler(),
      );
    diagnostics.capture();
    final http = (diagnostics.latest!['operations'] as Map)['http'] as Map;
    expect(http['active'], 0);
    expect(http['completed'], 2);
  });

  test('records rotate and recover after a failed write', () async {
    final file = File('${directory.path}/bounded.jsonl');
    final store = DiagnosticRecordStore(
      file,
      maxBytes: 140,
      retainedFiles: 2,
      maxPending: 8,
    );
    for (var i = 0; i < 10; i++) {
      store.add({'message': 'record-$i-${'x' * 40}'});
      await store.flush();
    }
    final files = await store.files();
    expect(files.length, lessThanOrEqualTo(2));
    for (final file in files) {
      expect(await file.length(), lessThanOrEqualTo(140));
    }
    expect(await file.readAsString(), contains('record-9'));
    final blocker = File('${directory.path}/blocked');
    await blocker.writeAsString('not a directory');
    final recoverable = DiagnosticRecordStore(
      File('${blocker.path}/log.jsonl'),
    )..add({'message': 'fails'});
    await recoverable.flush();
    expect(recoverable.dropped, 1);
    await blocker.delete();
    recoverable.add({'message': 'recovers'});
    await recoverable.flush();
    expect(await recoverable.file.readAsString(), contains('recovers'));
  });

  test(
    'slow writers drop excess work without retaining an unbounded queue',
    () async {
      final store = DiagnosticRecordStore(
        File('${directory.path}/queue.jsonl'),
        maxPending: 2,
      );
      for (var i = 0; i < 100; i++) {
        store.add({'index': i});
      }
      expect(store.dropped, 98);
      await store.flush();
      expect(await store.file.readAsLines(), hasLength(2));
    },
  );

  test(
    'export contains readable sanitized logs and performance records',
    () async {
      await diagnostics.configure(
        tracing: true,
        level: DiagnosticLogLevel.debug,
      );
      diagnostics.log(
        DiagnosticLogLevel.debug,
        'test',
        'token=export-secret-test',
      );
      final file = await diagnostics.exportArchive();
      try {
        final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
        expect(
          archive.files.map((file) => file.name),
          containsAll(['runtime.jsonl', 'performance.jsonl', 'manifest.json']),
        );
        for (final entry in archive.files) {
          final content = utf8.decode(entry.content);
          expect(content, isNot(contains('export-secret-test')));
          for (final line in const LineSplitter().convert(content)) {
            expect(jsonDecode(line), isA<Map>());
          }
        }
      } finally {
        await file.parent.delete(recursive: true);
      }
    },
  );

  test(
    'Windows native sampling returns process counters without helper processes',
    () {
      if (!Platform.isWindows) return;
      final metrics = ProcessMetrics();
      final first = metrics.sample();
      final second = metrics.sample();
      expect(first['rssBytes'], greaterThan(0));
      expect(first['privateBytes'], greaterThan(0));
      expect(second['cpuPercentMachine'], isA<num>());
      metrics.reset();
      expect(metrics.sample()['cpuPercentMachine'], isNull);
    },
  );

  testWidgets(
    'diagnostics page can enable sampling, stop it and change levels',
    (tester) async {
      final pageDiagnostics = Diagnostics(
        processReader: () => {'rssBytes': 123456},
      );
      addTearDown(pageDiagnostics.dispose);
      await tester.pumpWidget(
        MaterialApp(home: DiagnosticsPage(diagnostics: pageDiagnostics)),
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump(const Duration(milliseconds: 300));
      expect(pageDiagnostics.tracing, isTrue);
      expect(find.text('进程工作集'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump(const Duration(milliseconds: 300));
      expect(pageDiagnostics.tracing, isFalse);
      await tester.tap(find.text('日志等级'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('调试'));
      await tester.pumpAndSettle();
      expect(pageDiagnostics.level, DiagnosticLogLevel.debug);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _TestHttpAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/failure') {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
      );
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        'content-type': ['application/json'],
        'content-length': ['2'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _DisposedNativePlayer implements NativePlayer {
  @override
  bool get disposed => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Disposed player must not access native state');
}

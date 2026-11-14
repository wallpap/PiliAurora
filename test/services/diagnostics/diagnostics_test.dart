import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Canvas, FrameTiming, PictureRecorder;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

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

  test('player traffic preserves runtime warnings and route context', () {
    diagnostics
      ..routeChanged('/video?token=fixture')
      ..log(DiagnosticLogLevel.warning, 'app', 'keep warning');
    for (var i = 0; i < 250; i++) {
      diagnostics.playerLog(DiagnosticLogLevel.info, 'mpv', 'frame $i');
    }
    expect(diagnostics.recentLogs, hasLength(201));
    final warning = diagnostics.recentLogs.last;
    expect(warning['message'], 'keep warning');
    expect(warning['route'], '/video');
    expect(warning['processId'], pid);
  });

  test('Windows memory checkpoints survive redaction and deduplicate cached samples', () async {
    const channel = MethodChannel('pili_aurora/windows_memory');
    var sampleId = 1;
    final regions = List.generate(
      512,
      (i) => {
        'id': i + 1,
        'committedBytes': 1048576,
        'reservedBytes': 0,
        'privateCommittedBytes': 1048576,
        'privateReservedBytes': 0,
        'mappedCommittedBytes': 0,
        'imageCommittedBytes': 0,
        'privateReadWriteBytes': 1048576,
        'privateWriteCombineBytes': 0,
        'privateOtherBytes': 0,
        'regionCount': 1,
        'typeFlags': 0x20000,
        'protectionFlags': 4,
        'aboveThreshold': true,
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'sample'
              ? {
                  'status': 'sampled',
                  'sampleId': sampleId,
                  'tickMs': sampleId * 5000,
                  'complete': true,
                  'eventOverflow': 0,
                  'truncated': false,
                  'allocations': regions,
                  'changes': sampleId == 1
                      ? []
                      : [
                          {
                            'kind': 'changed',
                            'id': 1,
                            'before': regions.first,
                            'after': regions.first,
                          },
                        ],
                }
              : null,
        );
    try {
      await diagnostics.configure(tracing: true, level: DiagnosticLogLevel.off);
      for (var i = 0; i < 100 && diagnostics.recentLogs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      diagnostics.capture();
      final memory = diagnostics.latest!['memory'] as Map;
      expect(memory['largest'], hasLength(8));
      expect(jsonEncode(memory), isNot(contains('<truncated>')));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      sampleId = 3;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await diagnostics.configure(tracing: false);
      await diagnostics.flush();
      final exportResult = await diagnostics.exportArchive();
      final output = exportResult.file;
      late List<dynamic> records;
      try {
        final zip = ZipDecoder().decodeBytes(await output.readAsBytes());
        records = const LineSplitter()
            .convert(
              utf8.decode(
                zip.files.firstWhere((f) => f.name == 'runtime.jsonl').content,
              ),
            )
            .map((line) => jsonDecode(line) as Map)
            .toList();
      } finally {
        await exportResult.dispose();
      }
      final snapshots = records
          .where((r) => r['category'] == 'memory.snapshot')
          .toList();
      expect(snapshots, hasLength(2));
      expect((snapshots.last['details'] as Map)['skippedSnapshots'], 1);
      for (final id in [1, 3]) {
        final chunks = records.where(
          (r) =>
              r['category'] == 'memory.regions.checkpoint' &&
              (r['details'] as Map)['sampleId'] == id,
        );
        final restored = chunks
            .expand((r) => (r['details'] as Map)['regions'] as List)
            .toList();
        expect(restored, hasLength(512));
        expect((restored.last as Map)['id'], 512);
        expect(jsonEncode(chunks.toList()), isNot(contains('<truncated>')));
      }
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  }, skip: !Platform.isWindows);

  test(
    'graphics contexts keep complete resource batches and image lifetimes',
    () async {
      const channel = MethodChannel(
        'pili_aurora/graphics_memory',
        JSONMethodCodec(),
      );
      final resources = List.generate(
        64,
        (index) => {
          'id': 'resource_$index',
          'type': 'Texture',
          'category': 'Scratch',
          'bytes': 1048576,
          'purgeableBytes': 1048576,
          'wrapped': false,
          'backingType': 'gl_texture',
          'backingId': '$index',
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => {
              'status': 'sampled',
              'schemaVersion': 1,
              'sampleId': 41,
              'contexts': {
                for (final name in ['raster', 'io'])
                  name: {
                    'available': true,
                    'resourceBytes': 64 << 20,
                    'budgetBytes': 128 << 20,
                    'resources': resources,
                  },
              },
            },
          );
      try {
        await diagnostics.configure(
          tracing: true,
          level: DiagnosticLogLevel.off,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final recorder = PictureRecorder();
        Canvas(recorder);
        final picture = recorder.endRecording();
        final image = picture.toImageSync(16, 16);
        diagnostics.capture();
        expect(
          ((diagnostics.latest!['graphicsHandles'] as Map)['image']
              as Map)['currentHandles'],
          1,
        );
        image.dispose();
        picture.dispose();
        diagnostics.capture();
        expect(
          ((diagnostics.latest!['graphicsHandles'] as Map)['image']
              as Map)['currentHandles'],
          0,
        );
        final contexts =
            (diagnostics.latest!['graphicsMemory'] as Map)['contexts'] as Map;
        expect((contexts['raster'] as Map)['budgetBytes'], 128 << 20);
        expect((contexts['io'] as Map).containsKey('resources'), isFalse);
        await diagnostics.configure(tracing: false);
        await diagnostics.flush();
        final records = (await File(
          '${directory.path}/runtime.jsonl',
        ).readAsLines()).map((line) => jsonDecode(line) as Map).toList();
        for (final name in ['raster', 'io']) {
          final batches = records
              .where(
                (record) =>
                    record['category'] == 'memory.graphics.resources' &&
                    (record['details'] as Map)['context'] == name,
              )
              .toList();
          expect(batches, hasLength(8));
          expect(
            batches.expand(
              (record) => (record['details'] as Map)['resources'] as List,
            ),
            hasLength(64),
          );
          expect(jsonEncode(batches), isNot(contains('<truncated>')));
        }
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
    skip: !Platform.isWindows,
  );

  test('pre-initialization records are persisted on initialization', () async {
    final early = Diagnostics()
      ..log(DiagnosticLogLevel.error, 'bootstrap', 'startup failed');
    final target = Directory('${directory.path}/early');
    await early.initialize(directory: target);
    await early.flush();
    expect(
      await File('${target.path}/runtime.jsonl').readAsString(),
      contains('startup failed'),
    );
    expect(early.recentLogs, hasLength(1));
    early.dispose();
  });

  test(
    'forwarded records retain origin and defer redaction to export',
    () async {
      diagnostics.receiveRecord({
        'channel': 'player',
        'level': 'error',
        'processId': 123,
        'route': '/video',
        'message': 'decoder failed',
        'details': {'deviceId': 'fixture-device', 'token': 'fixture-token'},
      }, windowId: 4);
      await diagnostics.flush();
      final record = diagnostics.recentLogs.single;
      expect(record['processId'], 123);
      expect(record['windowId'], 4);
      final text = await File('${directory.path}/player.jsonl').readAsString();
      expect(text, contains('fixture-device'));
      expect(text, contains('fixture-token'));
      final exportResult = await diagnostics.exportArchive();
      final output = exportResult.file;
      try {
        final zip = ZipDecoder().decodeBytes(await output.readAsBytes());
        final exported = utf8.decode(
          zip.files.firstWhere((f) => f.name == 'player.jsonl').content,
        );
        expect(exported, isNot(contains('fixture-device')));
        expect(exported, isNot(contains('fixture-token')));
        expect(
          await File('${directory.path}/player.jsonl').readAsString(),
          text,
        );
      } finally {
        await exportResult.dispose();
      }
    },
  );

  test('flush awaits the forwarding acknowledgement', () async {
    var acknowledged = false;
    diagnostics.forwardFlush = () async {
      await Future<void>.delayed(Duration.zero);
      acknowledged = true;
    };
    await diagnostics.flush();
    expect(acknowledged, isTrue);
  });

  test('delayed forwarded records are displayed by origin time', () {
    diagnostics
      ..log(DiagnosticLogLevel.error, 'app', 'newer')
      ..receiveRecord({
        'time': '2000-01-01T00:00:00.000Z',
        'channel': 'runtime',
        'level': 'error',
        'message': 'older',
      }, windowId: 2);
    expect(diagnostics.recentLogs.map((record) => record['message']), [
      'newer',
      'older',
    ]);
  });

  test(
    'forwarding failure preserves local logs and child performance export',
    () async {
      final child = Diagnostics(processReader: () => {'rssBytes': 42});
      await child.initialize(
        directory: Directory('${directory.path}/window-2'),
        childProcess: true,
      );
      child
        ..forwardRecord = ((_) => false)
        ..log(DiagnosticLogLevel.error, 'app', 'offline failure');
      await child.configure(tracing: true);
      child.capture();
      await child.configure(tracing: false);
      await child.flush();
      expect(child.forwardingFailures, 1);
      expect(child.droppedRecords, 0);
      expect(
        await File('${directory.path}/window-2/runtime.jsonl').readAsString(),
        contains('offline failure'),
      );
      expect(
        await File('${directory.path}/window-2/performance.jsonl')
            .readAsString(),
        contains('rssBytes'),
      );
      final exportResult = await diagnostics.exportArchive();
      final archive = exportResult.file;
      try {
        final zip = ZipDecoder().decodeBytes(await archive.readAsBytes());
        expect(
          zip.files.map((file) => file.name),
          containsAll(['window-2-runtime.jsonl', 'window-2-performance.jsonl']),
        );
      } finally {
        await exportResult.dispose();
        child.dispose();
      }
      await diagnostics.clear();
      expect(
        File('${directory.path}/window-2/runtime.jsonl').existsSync(),
        isFalse,
      );
    },
  );

  test(
    'settings changes notify once and expose effective configuration',
    () async {
      var changes = 0;
      diagnostics.onSettingsChanged = () => changes++;
      await diagnostics.configure(
        level: DiagnosticLogLevel.debug,
        playerLevel: DiagnosticLogLevel.error,
        intervalMs: 250,
      );
      expect(changes, 1);
      expect(diagnostics.settings, {
        'level': 'debug',
        'playerLevel': 'error',
        'intervalMs': 250,
        'tracing': false,
      });
    },
  );

  test(
    'export coordinates child flush and includes its forwarding status',
    () async {
      final child = Diagnostics();
      await child.initialize(
        directory: Directory('${directory.path}/window-3'),
        childProcess: true,
        windowId: 3,
      );
      child
        ..forwardRecord = ((_) => false)
        ..log(DiagnosticLogLevel.error, 'app', 'queued before snapshot');
      diagnostics
        ..pauseChildren = () async {
          await child.pauseWrites();
          child.log(DiagnosticLogLevel.error, 'app', 'during snapshot');
        }
        ..resumeChildren = (() => Future<void>.sync(child.resumeWrites));
      final exportResult = await diagnostics.exportArchive();
      final archive = exportResult.file;
      try {
        final zip = ZipDecoder().decodeBytes(await archive.readAsBytes());
        final text = utf8.decode(
          zip.files
                  .firstWhere((f) => f.name == 'window-3-runtime.jsonl')
                  .content
              as List<int>,
        );
        expect(text, contains('queued before snapshot'));
        expect(text, isNot(contains('during snapshot')));
        final manifest = jsonDecode(
          utf8.decode(
            zip.files.firstWhere((f) => f.name == 'manifest.json').content
                as List<int>,
          ),
        ) as Map;
        final status = (manifest['children'] as List).single as Map;
        expect((status['storage'] as Map)['forwardingFailures'], 1);
        await child.flushLocal();
        expect(
          await File('${directory.path}/window-3/runtime.jsonl').readAsString(),
          contains('during snapshot'),
        );
      } finally {
        child.dispose();
        await child.flushLocal();
        await exportResult.dispose();
      }
    },
  );

  test(
    'clear coordinates child queues and retains records created afterward',
    () async {
      final child = Diagnostics();
      await child.initialize(
        directory: Directory('${directory.path}/window-4'),
        childProcess: true,
      );
      child.log(DiagnosticLogLevel.error, 'app', 'old record');
      diagnostics
        ..pauseChildren = child.pauseWrites
        ..clearChildren = () async {
          child.log(DiagnosticLogLevel.error, 'app', 'stale deferred record');
          await child.clearPausedRecords();
          child.log(DiagnosticLogLevel.error, 'app', 'after clear');
        }
        ..resumeChildren = (() => Future<void>.sync(child.resumeWrites));
      await diagnostics.clear();
      await child.flushLocal();
      final text = await File('${directory.path}/window-4/runtime.jsonl')
          .readAsString();
      expect(text, contains('after clear'));
      expect(text, isNot(contains('old record')));
      expect(text, isNot(contains('stale deferred record')));
      child.dispose();
    },
  );

  test('failed child coordination resumes writes and permits retry', () async {
    var resumes = 0;
    diagnostics
      ..pauseChildren = (() => Future<void>.error(StateError('not connected')))
      ..resumeChildren = () async {
        resumes++;
      };
    await expectLater(
      diagnostics.exportArchive(),
      _exportFailure(
        DiagnosticExportStage.snapshot,
        isA<StateError>(),
      ),
    );
    expect(resumes, 1);
    diagnostics.log(DiagnosticLogLevel.error, 'app', 'after failure');
    await diagnostics.flushLocal();
    expect(
      await File('${directory.path}/runtime.jsonl').readAsString(),
      contains('after failure'),
    );
    diagnostics.pauseChildren = null;
    final exportResult = await diagnostics.exportArchive();
    await exportResult.dispose();
  });

  test('resume failure preserves the original snapshot failure', () async {
    final primary = StateError('snapshot failed');
    diagnostics
      ..pauseChildren = (() => Future<void>.error(primary))
      ..resumeChildren = (() =>
          Future<void>.error(StateError('resume failed')));
    await expectLater(
      diagnostics.exportArchive(),
      _exportFailure(
        DiagnosticExportStage.snapshot,
        same(primary),
      ),
    );
    diagnostics.log(DiagnosticLogLevel.error, 'app', 'writes resumed');
    await diagnostics.flush().timeout(const Duration(seconds: 1));
    expect(
      await File('${directory.path}/runtime.jsonl').readAsString(),
      contains('writes resumed'),
    );
  });

  test('export manifest reports skipped malformed records', () async {
    final raw = File('${directory.path}/runtime.jsonl');
    await raw.writeAsString(
      '${jsonEncode({'channel': 'runtime', 'message': 'keep this'})}\n'
      'incomplete record\n',
    );
    final exportResult = await diagnostics.exportArchive();
    final archive = exportResult.file;
    try {
      final zip = ZipDecoder().decodeBytes(await archive.readAsBytes());
      final manifest = jsonDecode(
        utf8.decode(
          zip.files.firstWhere((f) => f.name == 'manifest.json').content,
        ),
      ) as Map;
      expect(manifest['export'], containsPair('skippedRecords', 1));
      expect(exportResult.skippedRecords, 1);
      expect(await raw.readAsString(), contains('incomplete record'));
    } finally {
      await exportResult.dispose();
    }
  });

  test(
    'closing flush waits for paused records to resume and persist',
    () async {
      await diagnostics.pauseWrites();
      diagnostics.log(DiagnosticLogLevel.error, 'window', 'late cleanup error');
      var flushed = false;
      final flush = diagnostics.flush().then((_) {
        flushed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);
      diagnostics.resumeWrites();
      await flush;
      expect(
        await File('${directory.path}/runtime.jsonl').readAsString(),
        contains('late cleanup error'),
      );
    },
  );

  test('paused buffer is byte bounded and prioritizes errors', () async {
    await diagnostics.pauseWrites();
    final chunk = 'x' * 65000;
    for (var i = 0; i < 40; i++) {
      diagnostics.playerLog(
        DiagnosticLogLevel.info,
        'mpv',
        chunk,
        details: {'a': chunk, 'b': chunk, 'c': chunk, 'd': chunk},
      );
    }
    diagnostics.playerLog(DiagnosticLogLevel.error, 'mpv', 'critical failure');
    final status = diagnostics.storageStatus['pausedBuffer'] as Map;
    expect(
      status['pendingBytes'],
      lessThanOrEqualTo(Diagnostics.maxDeferredBytes),
    );
    expect(status['pendingRecords'], lessThan(40));
    expect(diagnostics.droppedRecords, greaterThan(0));
    diagnostics.resumeWrites();
    await diagnostics.flush();
    expect(
      await File('${directory.path}/player.jsonl').readAsString(),
      contains('critical failure'),
    );
  });

  test('full paused queue evicts debug records for errors', () async {
    await diagnostics.configure(level: DiagnosticLogLevel.debug);
    await diagnostics.pauseWrites();
    final first = diagnostics.log(
      DiagnosticLogLevel.debug,
      'app',
      'old debug',
    )!;
    for (var i = 1; i < 400; i++) {
      diagnostics.log(DiagnosticLogLevel.debug, 'app', 'debug $i');
    }
    final error = diagnostics.log(
      DiagnosticLogLevel.error,
      'app',
      'keep error',
    )!;
    expect(await first.accepted, isFalse);
    expect(diagnostics.droppedRecords, 1);
    diagnostics.resumeWrites();
    expect(await error.accepted, isTrue);
    await diagnostics.flush();
    final text = await File('${directory.path}/runtime.jsonl').readAsString();
    expect(text, contains('keep error'));
    expect(text, isNot(contains('old debug')));
  });

  test(
    'uncoordinated child files are preserved and marked in export',
    () async {
      final childDirectory = Directory('${directory.path}/window-9');
      await childDirectory.create();
      final file = File('${childDirectory.path}/runtime.jsonl');
      await file.writeAsString('offline record');
      diagnostics.pauseChildren = () async {
        diagnostics.skippedChildWindows.add(9);
      };
      final exportResult = await diagnostics.exportArchive();
      final archive = exportResult.file;
      try {
        final zip = ZipDecoder().decodeBytes(await archive.readAsBytes());
        expect(
          zip.files.map((file) => file.name),
          isNot(contains('window-9-runtime.jsonl')),
        );
        final manifest = jsonDecode(
          utf8.decode(
            zip.files.firstWhere((file) => file.name == 'manifest.json').content
                as List<int>,
          ),
        ) as Map;
        expect((manifest['storage'] as Map)['skippedChildWindows'], [9]);
        await diagnostics.clear();
        expect(await file.readAsString(), 'offline record');
      } finally {
        await exportResult.dispose();
      }
    },
  );

  test(
    'export result owns stable completeness metadata and temporary files',
    () async {
      diagnostics
        ..pauseChildren = () async {
          diagnostics.skippedChildWindows.add(9);
        }
        ..resumeChildren = () async {
          diagnostics.skippedChildWindows.clear();
        }
        ..log(DiagnosticLogLevel.error, 'app', 'original stays local');
      final result = await diagnostics.exportArchive();
      try {
        expect(diagnostics.skippedChildWindows, isEmpty);
        expect(result.skippedChildWindows, {9});
        expect(result.skippedRecords, 0);
        expect(
          () => result.skippedChildWindows.add(10),
          throwsUnsupportedError,
        );
        expect(result.file.existsSync(), isTrue);
      } finally {
        await result.dispose();
      }
      await result.dispose();
      expect(result.file.parent.existsSync(), isFalse);
      expect(File('${directory.path}/runtime.jsonl').existsSync(), isTrue);
    },
  );

  test('unavailable temporary storage reports the prepare stage', () async {
    final blocked = File('${directory.path}/blocked-temp');
    await blocked.writeAsString('keep');
    await IOOverrides.runZoned(() async {
      await expectLater(
        diagnostics.exportArchive(),
        _exportFailure(
          DiagnosticExportStage.prepare,
          isA<FileSystemException>(),
        ),
      );
    }, getSystemTempDirectory: () => Directory(blocked.path));
    expect(await blocked.readAsString(), 'keep');
  });

  test('snapshot failure removes raw temporary copies', () async {
    final temporary = await Directory('${directory.path}/export-temp').create();
    diagnostics
      ..log(DiagnosticLogLevel.error, 'app', 'keep original')
      ..register('app', () => throw StateError('source failed'));
    await IOOverrides.runZoned(() async {
      await expectLater(
        diagnostics.exportArchive(),
        _exportFailure(
          DiagnosticExportStage.snapshot,
          isA<StateError>(),
        ),
      );
    }, getSystemTempDirectory: () => temporary);
    expect(await temporary.list().toList(), isEmpty);
    expect(File('${directory.path}/runtime.jsonl').existsSync(), isTrue);
  });

  test(
    'archive failure preserves its cause and removes temporary copies',
    () async {
      final temporary = await Directory('${directory.path}/export-temp')
          .create();
      diagnostics
        ..log(DiagnosticLogLevel.error, 'app', 'keep original')
        ..resumeChildren = () async {
          final snapshot =
              (await temporary.list().toList()).single as Directory;
          await File('${snapshot.path}/manifest.json').delete();
        };
      await IOOverrides.runZoned(() async {
        await expectLater(
          diagnostics.exportArchive(),
          _exportFailure(
            DiagnosticExportStage.archive,
            isA<FileSystemException>(),
          ),
        );
      }, getSystemTempDirectory: () => temporary);
      expect(await temporary.list().toList(), isEmpty);
      diagnostics
        ..resumeChildren = null
        ..log(DiagnosticLogLevel.error, 'app', 'after archive failure');
      await diagnostics.flush().timeout(const Duration(seconds: 1));
      expect(
        await File('${directory.path}/runtime.jsonl').readAsString(),
        contains('after archive failure'),
      );
    },
  );

  test('clearing records resets pause drops and forwarding failures', () async {
    diagnostics
      ..forwardRecord = ((_) => false)
      ..log(DiagnosticLogLevel.error, 'app', 'forward failed');
    await diagnostics.pauseWrites();
    for (var i = 0; i < 401; i++) {
      diagnostics.log(DiagnosticLogLevel.error, 'app', 'buffered $i');
    }
    expect(diagnostics.forwardingFailures, 1);
    expect(diagnostics.droppedRecords, greaterThan(0));
    await diagnostics.clearPausedRecords();
    diagnostics.resumeWrites();
    expect(diagnostics.forwardingFailures, 0);
    expect(diagnostics.droppedRecords, 0);
    expect((diagnostics.storageStatus['pausedBuffer'] as Map)['dropped'], 0);
  });

  test('pause flush failure immediately restores writes', () async {
    final failing = _FailingPauseDiagnostics();
    final target = Directory('${directory.path}/pause-failure');
    await failing.initialize(directory: target);
    failing.failNextFlush = true;
    try {
      await expectLater(
        failing.exportArchive(),
        _exportFailure(
          DiagnosticExportStage.snapshot,
          isA<StateError>(),
        ),
      );
      failing.log(DiagnosticLogLevel.error, 'app', 'after failed pause');
      await failing.flush().timeout(const Duration(seconds: 1));
      expect(
        await File('${target.path}/runtime.jsonl').readAsString(),
        contains('after failed pause'),
      );
    } finally {
      failing.dispose();
      await failing.flushLocal();
    }
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

  test('slow frames keep bounded wall times and reset after capture', () async {
    diagnostics
      ..register(
        'player',
        () => {
          for (var i = 0; i < 64; i++)
            'field$i': {'value': i, 'available': true},
        },
      )
      ..register(
        'danmaku.layer',
        () => {
          'scheduler': {'updates': 60, 'frameRequests': 60},
          'mediaAnchor': {'positionUs': 1000500},
          'token': 'fixture-private-value',
        },
      );
    await diagnostics.configure(tracing: true);
    const finish = 1700000000000000;
    final timings = List.generate(
      80,
      (_) => FrameTiming(
        vsyncStart: 0,
        buildStart: 1000,
        buildFinish: 21000,
        rasterStart: 22000,
        rasterFinish: 52000,
        rasterFinishWallTime: finish,
      ),
    );
    TestWidgetsFlutterBinding.instance.platformDispatcher.onReportTimings!(
      timings,
    );
    diagnostics.capture();
    final frames = diagnostics.latest!['frames'] as Map;
    final details = frames['slowFrameDetails'] as List;
    expect(frames['count'], 80);
    expect(frames['slowFrames'], 80);
    expect(details, hasLength(16));
    final layer =
        (diagnostics.latest!['sources'] as Map)['danmaku.layer'] as Map;
    expect(layer['scheduler'], containsPair('updates', 60));
    expect(layer['mediaAnchor'], containsPair('positionUs', 1000500));
    expect(
      jsonEncode(diagnostics.latest),
      contains('fixture-private-value'),
    );
    expect(diagnostics.latest!['diagnostics'], isA<Map>());
    expect(details.first, containsPair('buildMs', 20.0));
    expect(details.first, containsPair('rasterMs', 30.0));
    expect(
      details.first,
      containsPair(
        'buildStartUtc',
        DateTime.fromMicrosecondsSinceEpoch(
          finish - 51000,
          isUtc: true,
        ).toIso8601String(),
      ),
    );
    diagnostics.capture();
    expect((diagnostics.latest!['frames'] as Map)['slowFrameDetails'], isEmpty);
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

  test('restored logs sort correctly across a whole millisecond', () async {
    final records = [
      {
        'time': '2026-11-14T09:24:45.123Z',
        'runId': 'fixture',
        'sequence': 1,
        'channel': 'runtime',
        'message': 'older',
      },
      {
        'time': '2026-11-14T09:24:45.123001Z',
        'runId': 'fixture',
        'sequence': 2,
        'channel': 'runtime',
        'message': 'newer',
      },
      {
        'time': '2026-11-14T09:24:45.123001Z',
        'runId': 'fixture',
        'sequence': 3,
        'channel': 'runtime',
        'message': 'newest',
      },
      {
        'time': '2026-11-14T17:24:45.123002+08:00',
        'runId': 'fixture',
        'sequence': 4,
        'channel': 'runtime',
        'message': 'other timezone',
      },
      {
        'time': 'invalid',
        'runId': 'fixture',
        'sequence': 5,
        'channel': 'runtime',
        'message': 'unknown time',
      },
    ];
    await File('${directory.path}/runtime.jsonl').writeAsString(
      '${records.map(jsonEncode).join('\n')}\n',
    );
    final restored = Diagnostics(processReader: () => {});
    try {
      await restored.initialize(directory: directory);
      expect(restored.recentLogs.map((record) => record['message']), [
        'other timezone',
        'newest',
        'newer',
        'older',
        'unknown time',
      ]);
    } finally {
      restored.dispose();
      await restored.flush();
    }
  });

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
        "token=export-secret-test\nAudio 'track.m4s?e=export-signed-query&mid=export-user-id' (aac)",
      );
      final mutable = {
        'token': 'snapshot-secret',
        '${'x' * 100}Token': 'long-key-secret',
      };
      diagnostics
        ..register('player', () => {'nested': mutable})
        ..capture();
      mutable['token'] = 'later-value';
      expect(jsonEncode(diagnostics.latest), contains('snapshot-secret'));
      await diagnostics.flush();
      final raw = await File('${directory.path}/runtime.jsonl').readAsString();
      expect(raw, contains('export-secret-test'));
      final childDir = Directory('${directory.path}/window-9');
      await childDir.create();
      await File('${childDir.path}/runtime.jsonl').writeAsString(
        '${jsonEncode({
          'channel': 'runtime',
          'message': {'deviceId': 'child-device-secret'},
          'details': {'token': 'child-token-secret'},
        })}\ninvalid partial line',
      );
      await File('${childDir.path}/status.json')
          .writeAsString(jsonEncode({'token': 'child-status-secret'}));
      final exportResult = await diagnostics.exportArchive();
      final file = exportResult.file;
      try {
        final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
        expect(
          archive.files.map((file) => file.name),
          containsAll(['runtime.jsonl', 'performance.jsonl', 'manifest.json']),
        );
        expect(
          await File('${directory.path}/runtime.jsonl').readAsString(),
          raw,
        );
        for (final entry in archive.files) {
          final content = utf8.decode(entry.content);
          for (final secret in [
            'snapshot-secret',
            'long-key-secret',
            'child-device-secret',
            'child-token-secret',
            'child-status-secret',
          ]) {
            expect(content, isNot(contains(secret)));
          }
          expect(content, isNot(contains('export-secret-test')));
          expect(content, isNot(contains('export-signed-query')));
          expect(content, isNot(contains('export-user-id')));
          for (final line in const LineSplitter().convert(content)) {
            expect(jsonDecode(line), isA<Map>());
          }
        }
      } finally {
        await exportResult.dispose();
      }
    },
  );
}

class _FailingPauseDiagnostics extends Diagnostics {
  bool failNextFlush = false;
  @override
  Future<void> flushLocal() {
    if (failNextFlush) {
      failNextFlush = false;
      return Future<void>.error(StateError('pause flush failed'));
    }
    return super.flushLocal();
  }
}

Matcher _exportFailure(DiagnosticExportStage stage, Matcher cause) => throwsA(
  isA<DiagnosticExportException>()
      .having((error) => error.stage, 'stage', stage)
      .having((error) => error.cause, 'cause', cause),
);

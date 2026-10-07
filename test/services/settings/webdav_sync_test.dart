import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/services/settings/settings_backup.dart';
import 'package:pili_aurora/services/settings/webdav_client.dart';
import 'package:pili_aurora/services/settings/webdav_sync.dart';

const remotePath = 'backups/应用/settings_windows.json';
const restored = {
  'setting': {'theme': 'light', '语言': '中文'},
  'video': {'quality': 120},
};

class _RecordingClient extends WebDavSettingsClient {
  _RecordingClient(this.events, this.files)
    : super(
        endpoint: Uri.parse('https://example.invalid/root'),
        username: '',
        password: '',
      );

  final List<String> events;
  final Map<String, List<int>> files;
  Completer<void>? mkdirGate;
  Object? mkdirError;
  Object? readError;
  Object? writeError;
  int closes = 0;

  @override
  Future<void> ensureDirectory(String directory) async {
    events.add('mkdir:$directory');
    await mkdirGate?.future;
    if (mkdirError case final error?) throw error;
  }

  @override
  Future<void> write(String path, List<int> bytes) async {
    events.add('write:$path');
    if (writeError case final error?) throw error;
    files[path] = List<int>.of(bytes);
  }

  @override
  Future<List<int>> read(String path) async {
    events.add('read:$path');
    if (readError case final error?) throw error;
    return List<int>.of(files[path]!);
  }

  @override
  void close() {
    closes++;
    events.add('close');
    super.close();
  }
}

class _FailingBox implements Box<dynamic> {
  _FailingBox(this.beforeWrite);
  final void Function() beforeWrite;
  @override
  Map<dynamic, dynamic> toMap() => {'old': true};
  @override
  Future<void> putAll(Map<dynamic, dynamic> entries) {
    beforeWrite();
    return Future<void>.error(StateError('fixture storage write failure'));
  }

  @override
  Future<void> deleteAll(Iterable<dynamic> keys) =>
      fail('failed writes must not delete keys');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late Box<dynamic> setting;
  late Box<dynamic> video;
  late SettingsBackup settings;
  late List<String> events;
  late Map<String, List<int>> files;
  late List<_RecordingClient> clients;
  late WebDavSettingsSync sync;
  late void Function(_RecordingClient) configure;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pili-webdav-sync-test-');
    Hive.init(directory.path);
    setting = await Hive.openBox<dynamic>('setting');
    video = await Hive.openBox<dynamic>('video');
    await setting.putAll({'theme': 'dark', 'old': true});
    await video.putAll({'quality': 80, 'old': true});
    settings = SettingsBackup(setting: setting, video: video);
    events = [];
    files = {remotePath: utf8.encode(jsonEncode(restored))};
    clients = [];
    configure = (_) {};
    sync = WebDavSettingsSync(
      connect: () {
        final client = _RecordingClient(events, files);
        clients.add(client);
        configure(client);
        return client;
      },
      directory: 'backups/应用',
      fileName: 'settings_windows.json',
    );
  });

  tearDown(() async {
    for (final client in clients.where((client) => client.closes == 0)) {
      client.close();
    }
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'prepare creates the configured directory and releases the client',
    () async {
      await sync.prepare();
      expect(events, ['mkdir:backups/应用', 'close']);
      expect(clients.single.closes, 1);
    },
  );

  test(
    'failed directory creation still closes without changing the remote file',
    () async {
      final previous = List<int>.of(files[remotePath]!);
      configure = (client) =>
          client.mkdirError = StateError('fixture mkdir failure');
      await expectLater(sync.backup(settings), throwsStateError);
      expect(events, ['mkdir:backups/应用', 'close']);
      expect(files[remotePath], previous);
      expect(clients.single.closes, 1);
    },
  );

  test(
    'backup uploads UTF-8 JSON only after preparing the directory',
    () async {
      await setting.put('语言', '中文');
      await sync.backup(settings);
      expect(events, ['mkdir:backups/应用', 'write:$remotePath', 'close']);
      expect(utf8.decode(files[remotePath]!), settings.exportJson());
      expect(clients.single.closes, 1);
    },
  );

  test('backup content is fixed before network waits', () async {
    final snapshot = settings.exportJson();
    final gate = Completer<void>();
    configure = (client) => client.mkdirGate = gate;
    final operation = sync.backup(settings);
    expect(events, ['mkdir:backups/应用']);
    await setting.put('theme', 'changed after capture');
    gate.complete();
    await operation;
    expect(utf8.decode(files[remotePath]!), snapshot);
    expect(setting.get('theme'), 'changed after capture');
  });

  test(
    'upload failure propagates and closes without deleting the old backup',
    () async {
      final previous = List<int>.of(files[remotePath]!);
      configure = (client) =>
          client.writeError = const WebDavRequestException('PUT', 503);
      await expectLater(
        sync.backup(settings),
        throwsA(isA<WebDavRequestException>()),
      );
      expect(events, ['mkdir:backups/应用', 'write:$remotePath', 'close']);
      expect(files[remotePath], previous);
      expect(clients.single.closes, 1);
    },
  );

  test(
    'restore releases the connection and replaces only the two settings boxes',
    () async {
      final other = await Hive.openBox<dynamic>('other');
      await other.put('untouched', true);
      await sync.restore(settings);
      expect(events, ['read:$remotePath', 'close']);
      expect(setting.toMap(), restored['setting']);
      expect(video.toMap(), restored['video']);
      expect(other.toMap(), {'untouched': true});
      expect(clients.single.closes, 1);
    },
  );

  test('download failure closes and leaves local settings unchanged', () async {
    final previous = settings.exportJson();
    configure = (client) =>
        client.readError = const WebDavRequestException('GET', 404);
    await expectLater(
      sync.restore(settings),
      throwsA(isA<WebDavRequestException>()),
    );
    expect(settings.exportJson(), previous);
    expect(events, ['read:$remotePath', 'close']);
    expect(clients.single.closes, 1);
  });

  for (final fixture in <String, List<int>>{
    'invalid UTF-8': [0xc3, 0x28],
    'invalid JSON': utf8.encode('not JSON'),
    'missing section': utf8.encode('{"setting":{"theme":"light"}}'),
    'invalid section': utf8.encode('{"setting":{},"video":[]}'),
  }.entries) {
    test(
      'restore rejects ${fixture.key} without clearing local settings',
      () async {
        final previous = settings.exportJson();
        files[remotePath] = fixture.value;
        await expectLater(sync.restore(settings), throwsFormatException);
        expect(settings.exportJson(), previous);
        expect(events, ['read:$remotePath', 'close']);
        expect(clients.single.closes, 1);
      },
    );
  }

  test(
    'storage write errors propagate after the network client is closed',
    () async {
      void beforeWrite() => expectSync(events.last, 'close');
      final failingSettings = SettingsBackup(
        setting: _FailingBox(beforeWrite),
        video: _FailingBox(beforeWrite),
      );
      await expectLater(sync.restore(failingSettings), throwsStateError);
      expect(events, ['read:$remotePath', 'close']);
      expect(clients.single.closes, 1);
    },
  );

  test(
    'each operation uses a new client even on the same sync instance',
    () async {
      await sync.prepare();
      await sync.backup(settings);
      await sync.restore(settings);
      expect(clients, hasLength(3));
      expect(clients.every((client) => client.closes == 1), isTrue);
      expect(identical(clients[0], clients[1]), isFalse);
    },
  );

  test('connection factory failures remain observable', () async {
    sync = WebDavSettingsSync(
      connect: () => throw StateError('fixture connection failure'),
      directory: 'backups/应用',
      fileName: 'settings_windows.json',
    );
    await expectLater(sync.prepare(), throwsStateError);
    expect(events, isEmpty);
    expect(clients, isEmpty);
  });

  test(
    'real WebDAV client and Hive round trip through a loopback server',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      List<int>? uploaded;
      final subscription = server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        switch (request.method) {
          case 'MKCOL':
            request.response.statusCode = HttpStatus.created;
          case 'PUT':
            uploaded = await request.fold<List<int>>(
              [],
              (bytes, chunk) => bytes..addAll(chunk),
            );
            request.response.statusCode = HttpStatus.noContent;
          case 'GET':
            request.response.add(uploaded!);
          default:
            request.response.statusCode = HttpStatus.methodNotAllowed;
        }
        await request.response.close();
      });
      try {
        sync = WebDavSettingsSync(
          connect: () => WebDavSettingsClient(
            endpoint: Uri.parse('http://127.0.0.1:${server.port}/root'),
            username: '',
            password: '',
          ),
          directory: 'backups/应用',
          fileName: 'settings_windows.json',
        );
        final snapshot = settings.exportJson();
        await sync.backup(settings);
        await setting.put('theme', 'changed');
        await video.put('quality', 1);
        await sync.restore(settings);
        expect(settings.exportJson(), snapshot);
        expect(requests, [
          'MKCOL /root/backups/',
          'MKCOL /root/backups/%E5%BA%94%E7%94%A8/',
          'PUT /root/backups/%E5%BA%94%E7%94%A8/settings_windows.json',
          'GET /root/backups/%E5%BA%94%E7%94%A8/settings_windows.json',
        ]);
      } finally {
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );
}

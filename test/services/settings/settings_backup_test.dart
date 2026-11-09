import 'dart:convert';
import 'dart:io';

import 'package:pili_aurora/utils/credential_cipher.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/services/settings/settings_backup.dart';

class _RecordingBox implements Box<dynamic> {
  _RecordingBox(this.name, this.events, Map<dynamic, dynamic> initial)
    : data = Map<dynamic, dynamic>.of(initial);

  @override
  final String name;
  final List<String> events;
  final Map<dynamic, dynamic> data;
  bool failWrite = false;
  bool failDelete = false;

  @override
  Map<dynamic, dynamic> toMap() => Map<dynamic, dynamic>.of(data);

  @override
  Future<void> putAll(Map<dynamic, dynamic> entries) async {
    events.add('$name:write');
    if (failWrite) throw StateError('fixture write failure');
    data.addAll(entries);
  }

  @override
  Future<void> deleteAll(Iterable<dynamic> keys) async {
    events.add('$name:delete');
    if (failDelete) throw StateError('fixture delete failure');
    for (final key in keys) {
      data.remove(key);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('backup format and replacement policy', () {
    late List<String> events;
    late _RecordingBox setting;
    late _RecordingBox video;
    late SettingsBackup backup;

    setUp(() {
      events = [];
      setting = _RecordingBox('setting', events, {'theme': 'dark', 'old': 1});
      video = _RecordingBox('video', events, {'quality': 80, 'old': 2});
      backup = SettingsBackup(setting: setting, video: video);
    });

    test('不同入口的恢复按完整操作串行执行', () async {
      final other = SettingsBackup(setting: setting, video: video);
      final first = backup.restoreMap({
        'setting': {'theme': 'A'},
        'video': {},
      });
      final second = other.restoreMap({
        'setting': {'theme': 'B', 'old': 2},
        'video': {},
      });
      await Future.wait([first, second]);
      expect(setting.data, {'theme': 'B', 'old': 2});
    });

    test(
      'protects only the WebDAV password and imports legacy plaintext',
      () async {
        const key = SettingBoxKey.webdavPassword;
        setting.data[key] = 'fixture-password';
        final exported = backup.exportJson();
        expect(exported, isNot(contains('fixture-password')));
        final document = jsonDecode(exported) as Map;
        expect(document['setting']['theme'], 'dark');
        expect(
          CredentialCipher.decrypt(document['setting'][key]),
          'fixture-password',
        );
        await backup.restoreMap(document);
        expect(CredentialCipher.decrypt(setting.data[key]), 'fixture-password');
        document['setting'][key] = 'legacy-password';
        await backup.restoreMap(document);
        expect(setting.data[key], isNot('legacy-password'));
        expect(CredentialCipher.decrypt(setting.data[key]), 'legacy-password');
      },
    );

    test('rejects damaged credentials before changing any settings', () async {
      await expectLater(
        backup.restoreMap({
          'setting': {
            SettingBoxKey.webdavPassword: 'piliaurora:credential:v1:bad',
          },
          'video': {},
        }),
        throwsFormatException,
      );
      expect(events, isEmpty);
    });

    test(
      'nested lists and maps are compared by value rather than identity',
      () async {
        setting.data['nested'] = {
          'types': [1, 2],
          'enabled': true,
        };
        await backup.restoreJson(backup.exportJson());
        expect(events, isEmpty);
      },
    );

    test('empty sections intentionally remove their previous keys', () async {
      await backup.restoreMap({'setting': {}, 'video': {}});
      expect(setting.data, isEmpty);
      expect(video.data, isEmpty);
      expect(events.toSet(), {'setting:delete', 'video:delete'});
    });

    test('new null values are distinct from missing keys', () async {
      await backup.restoreMap({
        'setting': {'theme': 'dark', 'old': 1, 'nullable': null},
        'video': {'quality': 80, 'old': 2},
      });
      expect(setting.data.containsKey('nullable'), isTrue);
      expect(setting.data['nullable'], isNull);
      expect(events, ['setting:write']);
    });

    for (final document in <Object?>[
      null,
      [],
      {'setting': {}, 'video': []},
    ]) {
      test(
        'rejects malformed snapshot $document before touching either box',
        () async {
          await expectLater(backup.restoreMap(document), throwsFormatException);
          expect(events, isEmpty);
          expect(setting.data, {'theme': 'dark', 'old': 1});
          expect(video.data, {'quality': 80, 'old': 2});
        },
      );
    }

    test('invalid JSON fails through the returned Future and leaves storage untouched', () async {
      final operation = backup.restoreJson('{');
      await expectLater(operation, throwsFormatException);
      expect(events, isEmpty);
    });

    test(
      'an upsert failure never triggers deletion in either partition',
      () async {
        video.failWrite = true;
        await expectLater(
          backup.restoreMap({
            'setting': {'theme': 'light'},
            'video': {'quality': 120},
          }),
          throwsStateError,
        );
        expect(events.where((event) => event.endsWith(':delete')), isEmpty);
        expect(setting.data['old'], 1);
        expect(video.data, {'quality': 80, 'old': 2});
      },
    );

    test(
      'delete failure remains observable without clearing the snapshot',
      () async {
        setting.failDelete = true;
        await expectLater(
          backup.restoreMap({
            'setting': {'theme': 'light'},
            'video': {'quality': 120},
          }),
          throwsStateError,
        );
        expect(setting.data, {'theme': 'light', 'old': 1});
        expect(video.data['quality'], 120);
      },
    );

    test(
      'non-owned root metadata does not create new storage partitions',
      () async {
        await backup.restoreMap({
          'setting': {},
          'video': {},
          'metadata': {'version': 1},
        });
        expect(jsonDecode(backup.exportJson()), {'setting': {}, 'video': {}});
      },
    );

    test('map entrypoint preserves integer Hive keys', () async {
      await backup.restoreMap({
        'setting': {1: 'value'},
        'video': {},
      });
      expect(setting.data, {1: 'value'});
    });
  });

  group('real Hive round-trip', () {
    late Directory directory;
    late Box<dynamic> setting;
    late Box<dynamic> video;
    late SettingsBackup backup;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'pili-settings-backup-',
      );
      Hive.init(directory.path);
      setting = await Hive.openBox('setting');
      video = await Hive.openBox('video');
      backup = SettingsBackup(setting: setting, video: video);
    });
    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    test('nested settings and Unicode video preferences survive JSON restore and reopen', () async {
      await setting.putAll({
        'theme': 'dark',
        'filters': {
          'words': ['测试', '关键词'],
        },
      });
      await video.putAll({
        'BV-fixture': {'quality': 80, 'rate': 1.5},
      });
      final snapshot = backup.exportJson();
      await setting.put('obsolete', true);
      await video.put('obsolete', true);
      await backup.restoreJson(snapshot);
      expect(backup.exportJson(), snapshot);
      await Hive.close();
      setting = await Hive.openBox('setting');
      video = await Hive.openBox('video');
      expect(
        SettingsBackup(setting: setting, video: video).exportJson(),
        snapshot,
      );
    });

    test('invalid second partition never clears first partition', () async {
      await setting.put('preserved', '设置');
      await video.put('preserved', 80);
      await expectLater(
        backup.restoreMap({'setting': {}, 'video': 'invalid'}),
        throwsFormatException,
      );
      expect(setting.toMap(), {'preserved': '设置'});
      expect(video.toMap(), {'preserved': 80});
    });
  });
}

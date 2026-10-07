import 'dart:convert';
import 'dart:io';

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

    test('exports the existing two-section JSON schema and indentation', () {
      expect(jsonDecode(backup.exportJson()), {
        'setting': {'theme': 'dark', 'old': 1},
        'video': {'quality': 80, 'old': 2},
      });
      expect(backup.exportJson(), contains('\n    "setting": {'));
      expect(events, isEmpty);
    });

    test('identical snapshots perform no storage writes or deletes', () async {
      await backup.restoreJson(backup.exportJson());
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

    test('both upserts precede deletion of stale keys', () async {
      await backup.restoreMap({
        'setting': {'theme': 'light', 'new': true},
        'video': {'quality': 120},
      });
      expect(setting.data, {'theme': 'light', 'new': true});
      expect(video.data, {'quality': 120});
      expect(events.take(2).toSet(), {'setting:write', 'video:write'});
      expect(events.skip(2).toSet(), {'setting:delete', 'video:delete'});
    });

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
      {},
      {'setting': {}},
      {'video': {}},
      {'setting': null, 'video': {}},
      {'setting': {}, 'video': []},
      {
        'setting': {},
        'video': {true: 1},
      },
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

    test('invalid JSON leaves storage untouched', () {
      expect(() => backup.restoreJson('{'), throwsFormatException);
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

    test('unchanged nested values emit no Hive write events', () async {
      await setting.put('nested', {
        'types': [1, 2, 3],
      });
      final changes = <BoxEvent>[];
      final subscription = setting.watch().listen(changes.add);
      try {
        await backup.restoreJson(backup.exportJson());
        expect(changes, isEmpty);
      } finally {
        await subscription.cancel();
      }
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

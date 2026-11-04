import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

void main() {
  test(
    'startup migrates WebDAV plaintext and clears old file records',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'credential-migrate-',
      );
      try {
        appSupportDirPath = directory.path;
        Hive.init(path.join(directory.path, 'hive'));
        final old = await Hive.openBox('setting');
        await old.put(SettingBoxKey.webdavPassword, 'fixture-webdav-secret');
        await old.put('unrelated', 'preserved');
        await old.close();

        await GStorage.init();
        expect(Pref.webdavPassword, 'fixture-webdav-secret');
        expect(GStorage.setting.get('unrelated'), 'preserved');
        final snapshot = await GStorage.playbackSnapshot();
        expect(
          latin1.decode(snapshot['setting']!),
          isNot(contains('fixture-webdav-secret')),
        );
        expect(
          GStorage.settingsBackup.exportJson(),
          isNot(contains('fixture-webdav-secret')),
        );
      } finally {
        await Hive.close();
        Hive.resetAdapters();
        await directory.delete(recursive: true);
      }
    },
  );
}

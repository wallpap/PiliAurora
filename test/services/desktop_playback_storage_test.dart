import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models/model_owner.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  test('子窗口内存快照保留类型与配置，写入不影响主窗口文件', () async {
    final directory = Directory.systemTemp.createTempSync(
      'pili-window-storage-test-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final root = directory.path;
    // 各 isolate 串行打开并关闭临时存储，子窗口副本使用内存 Box。
    final snapshot = await Isolate.run(() async {
      appSupportDirPath = root;
      await GStorage.init();
      await GStorage.setting.put('desktopVolume', 0.8);
      await GStorage.localCache.put('sample', [1, 2, 3]);
      await GStorage.video.put('owner', Owner(mid: 42, name: 'sample'));
      final snapshot = await GStorage.playbackSnapshot();
      await GStorage.close();
      return snapshot;
    });
    final memoryValues = await Isolate.run(() async {
      appSupportDirPath = root;
      await GStorage.init(memorySnapshot: snapshot);
      final values = (
        volume: GStorage.setting.get('desktopVolume'),
        cache: GStorage.localCache.get('sample'),
        owner: (GStorage.video.get('owner') as Owner).mid,
        accountPath: Accounts.account.path,
        settingPath: GStorage.setting.path,
      );
      await GStorage.setting.put('desktopVolume', 0.2);
      await GStorage.close();
      return values;
    });
    expect(memoryValues.volume, 0.8);
    expect(memoryValues.cache, [1, 2, 3]);
    expect(memoryValues.owner, 42);
    expect(memoryValues.accountPath, isNull);
    expect(memoryValues.settingPath, isNull);
    final persistedVolume = await Isolate.run(() async {
      appSupportDirPath = root;
      await GStorage.init();
      final value = GStorage.setting.get('desktopVolume');
      await GStorage.close();
      return value;
    });
    expect(persistedVolume, 0.8);
  });
}

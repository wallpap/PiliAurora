import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('音量菜单打开期间鼠标离开与超时隐藏请求保持控件栏可见', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pili-controls-hover-',
    );
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
    GStorage.localCache = await Hive.openBox('cache');
    final controller = PlPlayerController.getInstance()..controls = false;
    addTearDown(() async {
      controller
        ..setControlsMenuOpen(false)
        ..controls = false;
      await Hive.close();
      await directory.delete(recursive: true);
    });
    controller.setControlsMenuOpen(true);
    expect(controller.showControls.value, isTrue);
    // 画面与浮层之间的鼠标进出沿用同一显示状态入口。
    for (var i = 0; i < 20; i++) {
      controller.controls = false;
      expect(controller.showControls.value, isTrue);
      controller.controls = true;
    }
    controller
      ..setControlsMenuOpen(false)
      ..controls = false;
    expect(controller.showControls.value, isFalse);
  });
}

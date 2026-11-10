import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/utils/calc_window_position.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

import '../support/memory_box.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  late List<Object?> displays;
  Object display({double x = 0, double y = 0, bool origin = true}) => {
    'id': 'display-$x',
    'size': {'width': 1920.0, 'height': 1080.0},
    'visibleSize': {'width': 1920.0, 'height': 1040.0},
    if (origin) 'visiblePosition': {'dx': x, 'dy': y},
  };
  Object? cursor;
  bool fail = false;
  setUpAll(() => GStorage.setting = MemoryBox());
  setUp(() async {
    await GStorage.setting.clear();
    displays = [display()];
    cursor = {'dx': 100.0, 'dy': 100.0};
    fail = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (fail) throw PlatformException(code: 'unavailable');
      return switch (call.method) {
        'getAllDisplays' => {'displays': displays},
        'getCursorScreenPoint' => cursor,
        'getPrimaryDisplay' => display(),
        _ => null,
      };
    });
  });
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );
  test('保存坐标支持正负屏幕原点，并优先恢复仍连接的显示器', () async {
    for (final origin in [1920.0, -1920.0]) {
      displays = [display(), display(x: origin)];
      await GStorage.setting.put(SettingBoxKey.windowPosition, [
        origin + 100,
        100,
      ]);
      expect(
        await calcWindowPosition(const Size(800, 600)),
        Offset(origin + 100, 100),
      );
    }
  });
  test('空原点、无效坐标和超大窗口安全降级，原生失败不阻断启动', () async {
    displays = [display(origin: false)];
    expect(
      await calcWindowPosition(const Size(800, 600)),
      const Offset(560, 220),
    );
    expect(await calcWindowPosition(const Size(4000, 2000)), Offset.zero);
    for (final invalid in [
      [],
      ['bad', 1],
      [double.nan, 0],
      'bad',
    ]) {
      await GStorage.setting.put(SettingBoxKey.windowPosition, invalid);
      expect(
        await calcWindowPosition(const Size(800, 600)),
        const Offset(560, 220),
      );
    }
    fail = true;
    expect(await calcWindowPosition(const Size(800, 600)), Offset.zero);
  });
  test('尺寸和位置偏好接收有限数值对，损坏值不修改持久记录', () async {
    await GStorage.setting.put(SettingBoxKey.windowSize, [1000, 800]);
    expect(Pref.windowSize, const Size(1000, 800));
    for (final invalid in [
      [],
      [0, 2],
      [double.infinity, 2],
      'invalid',
    ]) {
      await GStorage.setting.put(SettingBoxKey.windowSize, invalid);
      expect(Pref.windowSize, const Size(1180, 720));
      expect(GStorage.setting.get(SettingBoxKey.windowSize), invalid);
    }
  });
}

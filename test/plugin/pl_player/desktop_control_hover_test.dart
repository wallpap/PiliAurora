import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('音量菜单阻止鼠标离开和定时隐藏，关闭后恢复自动隐藏', (tester) async {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.video = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    final controller = PlPlayerController.getInstance()..controls = false;
    addTearDown(() {
      controller
        ..setControlsMenuOpen(false)
        ..controls = false;
    });
    controller.setControlsMenuOpen(true);
    expect(controller.showControls.value, isTrue);
    // 画面与浮层之间的鼠标进出沿用同一显示状态入口。
    for (var i = 0; i < 2; i++) {
      controller.controls = false;
      expect(controller.showControls.value, isTrue);
      controller.controls = true;
    }
    controller.hideTaskControls();
    await tester.pump(controller.showControlDuration);
    expect(controller.showControls.value, isTrue);
    controller.setControlsMenuOpen(false);
    await tester.pump(
      controller.showControlDuration - const Duration(milliseconds: 1),
    );
    expect(controller.showControls.value, isTrue);
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.showControls.value, isFalse);
  });
}

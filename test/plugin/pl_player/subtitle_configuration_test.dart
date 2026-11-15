import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'dragging subtitles updates display configuration and persisted position',
    () {
      GStorage.setting = MemoryBox<dynamic>();
      GStorage.video = MemoryBox<dynamic>();
      GStorage.localCache = MemoryBox<dynamic>();
      final controller = PlPlayerController.getInstance();
      final original = controller.subtitleConfig.value;
      controller.onUpdatePadding(const EdgeInsets.only(bottom: 38));
      expect(controller.subtitlePaddingB, 38);
      expect(controller.subtitleConfig.value.padding.bottom, 38);
      expect(controller.subtitleConfig.value.style, original.style);
      expect(GStorage.setting.get(SettingBoxKey.subtitlePaddingB), 38);
    },
  );
}

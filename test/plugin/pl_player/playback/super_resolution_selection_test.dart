import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models/common/super_resolution_type.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = MemoryBox<dynamic>();
  late PlPlayerController controller;

  setUpAll(() {
    GStorage.setting = settings;
    GStorage.video = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    controller = PlPlayerController.getInstance();
  });

  test('尺寸未确认时拒绝开启，保留当前档位和设置', () async {
    for (final current in [
      SuperResolutionType.disable,
      SuperResolutionType.efficiency,
    ]) {
      controller.superResolutionType.value = current;
      final before = Map.of(settings.data);
      await controller.setShader(SuperResolutionType.quality);
      expect(controller.superResolutionType.value, current);
      expect(settings.data, before);
    }
  });
}

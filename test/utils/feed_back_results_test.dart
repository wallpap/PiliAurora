import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/utils/feed_back.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUpAll(() => GStorage.setting = MemoryBox());
  tearDown(() {
    enableFeedback = true;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('触感插件失败由反馈入口消费，调用者继续执行', () async {
    enableFeedback = true;
    var calls = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) {
      expect(call.method, 'HapticFeedback.vibrate');
      calls++;
      return Future<Object?>.error(
        PlatformException(code: 'haptics_failed', message: 'private-value'),
      );
    });
    await feedBack();
    expect(calls, 1);
  });

  test('关闭触感时不调用插件，开启时使用轻触反馈', () async {
    final arguments = <Object?>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      arguments.add(call.arguments);
      return null;
    });
    enableFeedback = false;
    await feedBack();
    expect(arguments, isEmpty);
    enableFeedback = true;
    await feedBack();
    expect(arguments, ['HapticFeedbackType.lightImpact']);
  });
}

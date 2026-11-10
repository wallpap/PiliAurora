import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/connectivity_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluttercommunity.plus/connectivity');
  Object? response;
  bool fail = false;
  int calls = 0;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    response = ['wifi'];
    fail = false;
    calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          if (fail) {
            throw PlatformException(
              code: 'unavailable',
              message: 'private details',
            );
          }
          return response;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  for (final entry in [
    (['wifi'], true),
    (['mobile'], false),
    (['none'], false),
    (['vpn', 'wifi'], true),
  ]) {
    test('网络 ${entry.$1} 明确映射质量档位', () async {
      response = entry.$1;
      expect((await ConnectivityUtils.queryWiFi()).data, entry.$2);
      expect(await ConnectivityUtils.isWiFi, entry.$2);
    });
  }
  test('网络探测失败保留原因，初始化保守降级而非假定Wi-Fi', () async {
    fail = true;
    final result = await ConnectivityUtils.queryWiFi();
    expect(result, isA<Error>());
    final error = result as Error;
    expect(error.cause, isA<PlatformException>());
    expect(error.stackTrace, isNotNull);
    expect(error.toString(), isNot(contains('private details')));
    expect(await ConnectivityUtils.isWiFi, isFalse);
    fail = false;
    expect((await ConnectivityUtils.queryWiFi()).data, isTrue);
  });
  test('桌面保留既有质量档位且不调用移动网络探测', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect((await ConnectivityUtils.queryWiFi()).data, isFalse);
    expect(calls, 0);
  });
}

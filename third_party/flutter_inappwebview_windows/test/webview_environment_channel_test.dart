import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_windows/src/webview_environment/webview_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('each environment disposes its own native channel', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const factoryChannel =
        MethodChannel('com.pichillilorenzo/flutter_webview_environment');
    final created = <String>[];
    final disposed = <String>[];
    final channels = <MethodChannel>[];

    messenger.setMockMethodCallHandler(factoryChannel, (call) async {
      expect(call.method, 'create');
      final id = (call.arguments as Map)['id'] as String;
      created.add(id);
      final channel =
          MethodChannel('com.pichillilorenzo/flutter_webview_environment_$id');
      channels.add(channel);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'dispose');
        disposed.add(id);
        return null;
      });
      return null;
    });

    try {
      final factory = WindowsWebViewEnvironment.static();
      final first = await factory.create();
      final second = await factory.create();
      expect(first.id, isNot(second.id));
      expect(created, [first.id, second.id]);
      await first.dispose();
      await second.dispose();
      expect(disposed, [first.id, second.id]);
    } finally {
      messenger.setMockMethodCallHandler(factoryChannel, null);
      for (final channel in channels) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    }
  });
}

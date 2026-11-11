import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/webview_environment.dart';

class _Environment extends PlatformWebViewEnvironment {
  _Environment()
    : super.implementation(const PlatformWebViewEnvironmentCreationParams());

  var versionChecks = 0, creations = 0;

  @override
  Future<String?> getAvailableVersion({String? browserExecutableFolder}) async {
    versionChecks++;
    await Future<void>.delayed(Duration.zero);
    return 'test';
  }

  @override
  Future<PlatformWebViewEnvironment> create({
    WebViewEnvironmentSettings? settings,
  }) async {
    creations++;
    await Future<void>.delayed(Duration.zero);
    return this;
  }
}

class _Platform extends InAppWebViewPlatform {
  final environment = _Environment();
  @override
  PlatformWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      environment;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'concurrent native users create exactly one shared environment',
    () async {
      final platform = _Platform();
      InAppWebViewPlatform.instance = platform;
      await Future.wait([
        AppWebViewEnvironment.initialize(userDataPath: 'isolated-webview-test'),
        AppWebViewEnvironment.initialize(userDataPath: 'isolated-webview-test'),
      ]);
      expect(platform.environment.versionChecks, 1);
      expect(platform.environment.creations, 1);
      expect(AppWebViewEnvironment.instance, isNotNull);
    },
  );
}

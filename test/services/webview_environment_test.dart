import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/webview_environment.dart';

class _Environment extends PlatformWebViewEnvironment {
  _Environment()
    : super.implementation(const PlatformWebViewEnvironmentCreationParams());
  var versions = 0, attempts = 0;
  String? path;

  @override
  Future<String?> getAvailableVersion({String? browserExecutableFolder}) async {
    versions++;
    return 'test';
  }

  @override
  Future<PlatformWebViewEnvironment> create({
    WebViewEnvironmentSettings? settings,
  }) async {
    path = settings?.userDataFolder;
    if (++attempts == 1) throw StateError('native environment unavailable');
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
    'configuration allocates nothing; first use retries after a shared failure',
    () async {
      final platform = _Platform();
      InAppWebViewPlatform.instance = platform;
      AppWebViewEnvironment.configure(userDataPath: 'isolated-webview-test');
      expect(platform.environment.versions, 0);
      expect(platform.environment.attempts, 0);
      final first = AppWebViewEnvironment.ensureInitialized();
      final second = AppWebViewEnvironment.ensureInitialized();
      expect(identical(first, second), isTrue);
      await expectLater(Future.wait([first, second]), throwsStateError);
      expect(AppWebViewEnvironment.instance, isNull);
      await AppWebViewEnvironment.ensureInitialized();
      await AppWebViewEnvironment.ensureInitialized();
      expect(platform.environment.attempts, 2);
      expect(platform.environment.versions, 2);
      expect(platform.environment.path, 'isolated-webview-test');
      expect(
        () => AppWebViewEnvironment.configure(userDataPath: 'another-account'),
        throwsStateError,
      );
    },
  );
}

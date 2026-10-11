import 'package:pili_aurora/app/back_navigation.dart';
import 'package:pili_aurora/app/desktop_playback_launch.dart';
import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/common/widgets/app_viewport.dart';
import 'package:pili_aurora/common/widgets/back_detector.dart';
import 'package:pili_aurora/common/widgets/custom_toast.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/common/widgets/scroll_behavior.dart';
import 'package:pili_aurora/router/app_pages.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/desktop_playback_request.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 提供应用主题、本地化、路由、全局对话框和导航观察器。
class PiliAuroraApp extends StatelessWidget {
  const PiliAuroraApp({super.key, this.playbackRequest});
  final DesktopPlaybackRequest? playbackRequest;

  @override
  Widget build(BuildContext context) {
    final (light, dark) = ThemeUtils.getAllTheme();
    return GetMaterialApp(
      title: Constants.appName,
      theme: light,
      darkTheme: dark,
      themeMode: ThemeUtils.themeMode = Pref.themeMode,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      locale: const Locale("zh", "CN"),
      fallbackLocale: const Locale("zh", "CN"),
      supportedLocales: const [Locale("zh", "CN"), Locale("en", "US")],
      initialRoute: playbackRequest == null ? '/' : '/desktopPlayer',
      getPages: [
        ...Routes.getPages,
        if (playbackRequest case final request?)
          GetPage(
            name: '/desktopPlayer',
            page: () => DesktopPlaybackLaunch(request: request),
          ),
      ],
      defaultTransition: Pref.pageTransition,
      builder: FlutterSmartDialog.init(
        toastBuilder: CustomToast.new,
        loadingBuilder: LoadingWidget.new,
        notifyStyle: const FlutterSmartNotifyStyle(
          warningBuilder: NotifyWarning.new,
        ),
        builder: _builder,
      ),
      navigatorObservers: [
        DiagnosticRouteObserver(),
        routeObserver,
        FlutterSmartDialog.observer,
      ],
      scrollBehavior: PlatformUtils.isDesktop
          ? const CustomScrollBehavior()
          : null,
    );
  }

  static Widget _builder(BuildContext context, Widget? child) {
    final viewport = AppViewport(
      uiScale: Pref.uiScale,
      textScale: Pref.defaultTextScale,
      child: child!,
    );
    return PlatformUtils.isDesktop
        ? BackDetector(onBack: handleAppBack, child: viewport)
        : viewport;
  }
}

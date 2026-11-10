import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/models/common/theme/theme_color_type.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/extension/core_palettes_ext.dart';
import 'package:pili_aurora/utils/extension/theme_ext.dart';
import 'package:pili_aurora/utils/font_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoThemeData;
import 'package:dynamic_color/dynamic_color.dart' show DynamicColorPlugin;
import 'package:flutter/foundation.dart' show PlatformDispatcher;
import 'package:material_color_utilities/palettes/tonal_palette.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/app_menu_theme.dart';

abstract final class ThemeUtils {
  static ColorScheme? _light, _dark;

  static (ThemeData, ThemeData) getAllTheme() {
    final dynamicColor = _light != null && _dark != null && Pref.dynamicColor;

    final ColorScheme lightScheme, darkScheme;
    if (dynamicColor) {
      lightScheme = _light!;
      darkScheme = _dark!;
    } else {
      final customColor = Pref.customColor;
      final brandColor =
          colorThemeTypes.elementAtOrNull(customColor)?.color ??
          Color(customColor);
      final variant = Pref.schemeVariant;

      lightScheme = brandColor.asColorSchemeSeed(variant, .light);
      darkScheme = brandColor.asColorSchemeSeed(variant, .dark);
    }

    return (
      lightTheme = ThemeUtils.getThemeData(
        colorScheme: lightScheme,
        isDynamic: dynamicColor,
      ),
      darkTheme = ThemeUtils.getThemeData(
        isDark: true,
        colorScheme: darkScheme,
        isDynamic: dynamicColor,
      ),
    );
  }

  static Future<bool>? _platformInitialization;

  /// 只探测平台能力，不覆盖用户已经保存的动态取色偏好。
  static Future<bool> initPlatformState() {
    if (_light != null && _dark != null) return Future.value(true);
    return _platformInitialization ??= _loadPlatformColors().whenComplete(() {
      _platformInitialization = null;
    });
  }

  static Future<bool> _loadPlatformColors() async {
    try {
      final colors = await DynamicColorPlugin.channel.invokeMethod<Object?>(
        DynamicColorPlugin.methodName,
      );
      if (colors != null) {
        if (colors is! List ||
            colors.length != 5 * TonalPalette.commonSize ||
            colors.any(
              (color) =>
                  color is! int || color < -0x80000000 || color > 0xffffffff,
            )) {
          throw const FormatException('平台调色板数据无效');
        }
        final palettes = CorePalettesExt.fromList(
          colors.cast<int>().map((color) => color & 0xffffffff).toList(),
        );
        final light = palettes.toColorScheme();
        final dark = palettes.toColorScheme(brightness: Brightness.dark);
        _light = light;
        _dark = dark;
        return true;
      }
    } catch (error, stackTrace) {
      logger.w('读取平台调色板失败', error: error.runtimeType, stackTrace: stackTrace);
    }
    try {
      final accent = await DynamicColorPlugin.channel.invokeMethod<Object?>(
        DynamicColorPlugin.accentColorMethodName,
      );
      if (accent != null) {
        if (accent is! int || accent < -0x80000000 || accent > 0xffffffff) {
          throw const FormatException('平台强调色数据无效');
        }
        final variant = Pref.schemeVariant;
        final light = Color(accent & 0xffffffff)
            .asColorSchemeSeed(variant, .light);
        final dark = Color(accent & 0xffffffff)
            .asColorSchemeSeed(variant, .dark);
        _light = light;
        _dark = dark;
        return true;
      }
    } catch (error, stackTrace) {
      logger.w('读取平台强调色失败', error: error.runtimeType, stackTrace: stackTrace);
    }
    return false;
  }

  static late ThemeData lightTheme;

  static late ThemeData darkTheme;

  static late ThemeMode themeMode;

  static ThemeData get theme {
    if (themeMode == .dark ||
        (themeMode == .system &&
            PlatformDispatcher.instance.platformBrightness == .dark)) {
      return darkTheme;
    }
    return lightTheme;
  }

  static bool get isDarkMode => theme.isDark;

  static String themeUrl(bool isDark) =>
      'native.theme=${isDark ? 2 : 1}&night=${isDark ? 1 : 0}';

  static ThemeData getThemeData({
    required ColorScheme colorScheme,
    required bool isDynamic,
    bool isDark = false,
  }) {
    final fontWeight = Pref.appFontWeight;
    final fontFamily = FontUtils.fontFamily;

    TextTheme? textTheme;
    if (fontWeight != .normal) {
      final textStyle = TextStyle(fontWeight: fontWeight);
      textTheme = TextTheme(
        displayLarge: textStyle,
        displayMedium: textStyle,
        displaySmall: textStyle,
        headlineLarge: textStyle,
        headlineMedium: textStyle,
        headlineSmall: textStyle,
        titleLarge: textStyle,
        titleMedium: textStyle,
        titleSmall: textStyle,
        bodyLarge: textStyle,
        bodyMedium: textStyle,
        bodySmall: textStyle,
        labelLarge: textStyle,
        labelMedium: textStyle,
        labelSmall: textStyle,
      );
    }

    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: fontFamily,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        elevation: 0,
        titleSpacing: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        backgroundColor: colorScheme.surface,
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: fontWeight,
          fontFamily: fontFamily,
          color: colorScheme.onSurface,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        surfaceTintColor: isDark ? colorScheme.surfaceContainerHighest : null,
      ),
      snackBarTheme: SnackBarThemeData(
        elevation: 20,
        actionTextColor: colorScheme.primary,
        closeIconColor: colorScheme.secondary,
        backgroundColor: colorScheme.secondaryContainer,
        contentTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontWeight: fontWeight,
          color: colorScheme.onSecondaryContainer,
        ),
      ),
      popupMenuTheme: AppMenuTheme.popupMenuThemeData(colorScheme),
      menuTheme: AppMenuTheme.menuThemeData(colorScheme),
      cardTheme: CardThemeData(
        elevation: 1,
        margin: EdgeInsets.zero,
        shadowColor: Colors.transparent,
        surfaceTintColor: isDark ? colorScheme.onSurfaceVariant : null,
      ),
      progressIndicatorTheme: isDark
          ? ProgressIndicatorThemeData(
              // ignore: deprecated_member_use
              year2023: false,
              refreshBackgroundColor: colorScheme.onInverseSurface,
            )
          // ignore: deprecated_member_use
          : const ProgressIndicatorThemeData(year2023: false),
      dialogTheme: DialogThemeData(
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: fontWeight,
          fontFamily: fontFamily,
          color: colorScheme.onSurface,
        ),
        backgroundColor: colorScheme.surface,
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: Style.bottomSheetRadius,
        ),
      ),
      // ignore: deprecated_member_use
      sliderTheme: const SliderThemeData(year2023: false),
      tooltipTheme: TooltipThemeData(
        textStyle: TextStyle(
          fontSize: 14,
          color: Colors.white,
          fontFamily: fontFamily,
          fontWeight: fontWeight,
        ),
        decoration: const BoxDecoration(
          color: Color(0xE6616161), // Colors.grey[700]!.withValues(alpha: 0.9)
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
      ),
      cupertinoOverrideTheme: CupertinoThemeData(
        selectionHandleColor: colorScheme.primary,
      ),
      switchTheme: const SwitchThemeData(
        padding: .zero,
        materialTapTargetSize: .shrinkWrap,
        thumbIcon: WidgetStateProperty<Icon?>.fromMap(
          <WidgetStatesConstraint, Icon?>{
            WidgetState.selected: Icon(Icons.done),
            WidgetState.any: null,
          },
        ),
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        shape: Border(),
        collapsedShape: Border(),
      ),
      listTileTheme: const ListTileThemeData(controlAffinity: .leading),
      filledButtonTheme: const FilledButtonThemeData(
        style: ButtonStyle(
          shadowColor: WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(),
        },
      ),
    );
    if (isDark && Pref.isPureBlackTheme) {
      return darkenTheme(theme);
    }
    return theme;
  }

  static ThemeData darkenTheme(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final color = colorScheme.surfaceContainerHighest.darken(0.7);
    return theme.copyWith(
      canvasColor: Colors.black,
      scaffoldBackgroundColor: Colors.black,
      appBarTheme: theme.appBarTheme.copyWith(
        backgroundColor: Colors.black,
      ),
      cardTheme: theme.cardTheme.copyWith(
        color: colorScheme.surfaceContainer.darken(0.75),
      ),
      dialogTheme: theme.dialogTheme.copyWith(backgroundColor: color),
      bottomSheetTheme: theme.bottomSheetTheme.copyWith(
        backgroundColor: color,
      ),
      bottomNavigationBarTheme: theme.bottomNavigationBarTheme.copyWith(
        backgroundColor: color,
      ),
      navigationBarTheme: theme.navigationBarTheme.copyWith(
        backgroundColor: color,
      ),
      navigationRailTheme: theme.navigationRailTheme.copyWith(
        backgroundColor: Colors.black,
      ),
      popupMenuTheme: theme.popupMenuTheme.copyWith(color: color),
      menuTheme: MenuThemeData(
        style: theme.menuTheme.style?.copyWith(
          backgroundColor: WidgetStatePropertyAll<Color?>(color),
        ),
        submenuIcon: theme.menuTheme.submenuIcon,
      ),
      colorScheme: colorScheme.copyWith(
        primary: colorScheme.primary.darken(0.1),
        onPrimary: colorScheme.onPrimary.darken(0.1),
        primaryContainer: colorScheme.primaryContainer.darken(0.1),
        onPrimaryContainer: colorScheme.onPrimaryContainer.darken(0.1),
        inversePrimary: colorScheme.inversePrimary.darken(0.1),
        secondary: colorScheme.secondary.darken(0.05),
        onSecondary: colorScheme.onSecondary.darken(0.05),
        secondaryContainer: colorScheme.secondaryContainer.darken(0.05),
        onSecondaryContainer: colorScheme.onSecondaryContainer.darken(0.05),
        error: colorScheme.error.darken(0.05),
        surface: Colors.black,
        onSurface: colorScheme.onSurface.darken(0.15),
        surfaceTint: colorScheme.surfaceTint.darken(),
        inverseSurface: colorScheme.inverseSurface.darken(),
        onInverseSurface: colorScheme.onInverseSurface.darken(),
        surfaceContainer: colorScheme.surfaceContainer.darken(),
        surfaceContainerHigh: colorScheme.surfaceContainerHigh.darken(),
        surfaceContainerHighest: colorScheme.surfaceContainerHighest.darken(
          0.4,
        ),
      ),
    );
  }
}

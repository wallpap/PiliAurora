import 'dart:ffi';
import 'dart:io' show File;
import 'dart:typed_data';
import 'dart:ui' show loadFontFromList;

import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:ffi/ffi.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, defaultTargetPlatform;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:jni/jni.dart';
import 'package:path/path.dart' as path;
import 'package:win32/win32.dart';

typedef AppFont = ({String? fontFamily, bool isCustom});

abstract final class FontUtils {
  static final _fonts = <String>{};
  static bool _initialized = false;

  static const _kFontExts = ['ttf', 'ttc', 'otf'];

  static AppFont _appFont = _initAppFont();
  static AppFont get appFont => _appFont;
  static set appFont(AppFont value) {
    assert(value.isCustom == _isCutsomFont(value.fontFamily));
    _appFont = value;
  }

  static bool _isCutsomFont(String? fontFamily) {
    return fontFamily?.contains('/') ?? false;
  }

  static AppFont _initAppFont() {
    final String? appFont = GStorage.setting.get(SettingBoxKey.appFont);
    if (_isCutsomFont(appFont)) {
      if (fontFile.existsSync()) {
        return (fontFamily: appFont, isCustom: true);
      } else {
        GStorage.setting.delete(SettingBoxKey.appFont);
        return const (fontFamily: null, isCustom: false);
      }
    } else {
      return (fontFamily: appFont, isCustom: false);
    }
  }

  static String? get fontFamily => _appFont.fontFamily;
  static bool get isCustom => _appFont.isCustom;

  static final fontFile = File(path.join(appSupportDirPath, 'customFont.otf'));

  static Future<void>? init() {
    if (isCustom) {
      return _readAndLoad();
    }
    return null;
  }

  @pragma('vm:notify-debugger-on-exception')
  static Future<void> _readAndLoad() async {
    try {
      final bytes = await fontFile.readAsBytes();
      await _loadFont(bytes, fontFamily: fontFamily!);
    } catch (_) {}
  }

  static void removeFontIfExists() {
    if (fontFile.existsSync()) {
      fontFile.delete();
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  static Future<void> _loadFont(
    Uint8List bytes, {
    required String fontFamily,
  }) async {
    try {
      await loadFontFromList(bytes, fontFamily: fontFamily);
    } catch (_) {}
  }

  @pragma('vm:notify-debugger-on-exception')
  static Future<Map<String, Uint8List>?> pickFonts() async {
    try {
      final files = await FilePicker.pickFiles(
        type: .custom,
        allowedExtensions: _kFontExts,
      );
      if (files.isNotEmpty) {
        final Map<String, Uint8List> fonts = {};
        final now = DateTime.now().millisecondsSinceEpoch.toString();
        await Future.wait(
          files.map((file) async {
            final name = '$now/${path.basenameWithoutExtension(file.name)}';
            final bytes = await file.readAsBytes();
            await _loadFont(bytes, fontFamily: name);
            fonts[name] = bytes;
          }),
        );
        return fonts;
      }
    } catch (_) {
      if (kDebugMode) rethrow;
    }
    return null;
  }

  static Set<String> getFont() {
    if (_initialized) return _fonts;
    _initialized = true;
    if (!switch (defaultTargetPlatform) {
      .android => _initAndroid(),
      .windows => _initWindows(),
      _ => true,
    }) {
      SmartDialog.showToast('加载系统字体失败');
    }
    return _fonts;
  }

  static int _enumFontCallback(
    Pointer<LOGFONT> lpelfe,
    Pointer<TEXTMETRIC> lpntme,
    int fontType,
    int lParam,
  ) {
    final familyName = lpelfe.ref.lfFaceName;
    if (familyName.startsWith('@')) return 1;
    _fonts.add(lpelfe.ref.lfFaceName);
    return 1;
  }

  @pragma('vm:prefer-inline')
  static bool _initWindows() {
    final hdc = GetDC(null);

    final logfont = calloc<LOGFONT>();
    logfont.ref.lfCharSet = DEFAULT_CHARSET;
    logfont.ref.lfFaceName = '';

    try {
      final result = EnumFontFamiliesEx(
        hdc,
        logfont,
        Pointer.fromFunction(_enumFontCallback, 0),
        const LPARAM(0),
        0,
      );

      return result != 0;
    } finally {
      calloc.free(logfont);
      ReleaseDC(null, hdc);
    }
  }

  @pragma('vm:prefer-inline')
  static bool _initAndroid() {
    final fontFamilies = AndroidHelper.fontFamilies();
    if (fontFamilies != null) {
      try {
        final length = fontFamilies.length;
        for (var i = 0; i < length; i++) {
          _fonts.add(fontFamilies[i]!.toDartString(releaseOriginal: true));
        }
        return true;
      } finally {
        fontFamilies.release();
      }
    }
    return false;
  }
}

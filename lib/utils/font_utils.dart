import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show File;
import 'dart:typed_data';
import 'dart:ui' show loadFontFromList;

import 'package:pili_aurora/utils/android/bindings.g.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:ffi/ffi.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:jni/jni.dart';
import 'package:path/path.dart' as path;
import 'package:win32/win32.dart';

typedef AppFont = ({String? fontFamily, bool isCustom});

abstract final class FontUtils {
  static final _fonts = <String>{};
  static bool _initialized = false;

  static const _kFontExts = ['ttf', 'ttc', 'otf'];

  static AppFont _appFont = (fontFamily: null, isCustom: false);
  static AppFont get appFont => _appFont;
  static String? get fontFamily => _appFont.fontFamily;
  static bool get isCustom => _appFont.isCustom;
  static bool _saving = false;

  static File get _legacyFontFile =>
      File(path.join(appSupportDirPath, 'customFont.otf'));

  static File _fontFile(String family) => File(
    path.join(
      appSupportDirPath,
      'customFont-${sha256.convert(utf8.encode(family))}.otf',
    ),
  );

  static Error _failure(String message, Object cause, StackTrace stackTrace) {
    logger.w(message, error: cause.runtimeType, stackTrace: stackTrace);
    return Error(message, cause: cause, stackTrace: stackTrace);
  }

  /// 字体是可选启动资源，失败保留偏好供重试，当前会话使用默认字体。
  static Future<LoadingState<void>> init() async {
    _appFont = (fontFamily: null, isCustom: false);
    try {
      final String? family = GStorage.setting.get(SettingBoxKey.appFont);
      if (family == null || !family.contains('/')) {
        _appFont = (fontFamily: family, isCustom: false);
        return const Success(null);
      }
      final file = _fontFile(family);
      final source = file.existsSync() || family.startsWith('custom:')
          ? file
          : _legacyFontFile;
      final bytes = await source.readAsBytes();
      await _loadFont(bytes, family);
      _appFont = (fontFamily: family, isCustom: true);
      return const Success(null);
    } catch (error, stackTrace) {
      return Error('自定义字体加载失败，已使用默认字体', cause: error, stackTrace: stackTrace);
    }
  }

  static Future<LoadingState<void>> saveSettings({
    required AppFont font,
    Uint8List? bytes,
    required int weight,
    required double scale,
  }) async {
    if (_saving) return const Error('字体设置正在保存，请稍候');
    if (font.isCustom != (font.fontFamily?.contains('/') ?? false) ||
        weight < 0 ||
        weight > 8 ||
        !scale.isFinite ||
        scale < 0.85 ||
        scale > 1.6) {
      return const Error('字体设置无效，请重新选择');
    }
    final previous = _appFont;
    File? pendingFile;
    var removePending = false;
    _saving = true;
    try {
      if (font.isCustom && font != previous) {
        if (bytes == null || bytes.isEmpty) return const Error('请重新导入所选字体');
        await _loadFont(bytes, font.fontFamily!);
        pendingFile = _fontFile(font.fontFamily!);
        removePending = !pendingFile.existsSync();
        await pendingFile.writeAsBytes(bytes, flush: true);
      }
      // 新旧字体使用独立文件；偏好写入失败不会破坏旧字体的磁盘内容。
      await GStorage.setting.putAll({
        SettingBoxKey.appFont: font.fontFamily,
        SettingBoxKey.appFontWeightV2: weight,
        SettingBoxKey.defaultTextScale: scale,
      });
      _appFont = font;
      removePending = false;
      if (previous.isCustom && previous != font) {
        await _removeFile(_fontFile(previous.fontFamily!));
        await _removeFile(_legacyFontFile);
      }
      return const Success(null);
    } catch (error, stackTrace) {
      return _failure('字体设置保存失败，请重试', error, stackTrace);
    } finally {
      if (removePending && pendingFile != null) await _removeFile(pendingFile);
      _saving = false;
    }
  }

  static Future<void> _removeFile(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (error, stackTrace) {
      // 偏好已确认，清理失败不能把成功保存改报为失败。
      logger.w('旧字体文件清理失败', error: error.runtimeType, stackTrace: stackTrace);
    }
  }

  static Future<void> _loadFont(Uint8List bytes, String family) async {
    if (bytes.isEmpty) throw const FormatException('字体文件为空');
    await loadFontFromList(bytes, fontFamily: family);
  }

  static Future<LoadingState<Map<String, Uint8List>?>> pickFonts() async {
    try {
      final files = await FilePicker.pickFiles(
        type: .custom,
        allowedExtensions: _kFontExts,
      );
      if (files.isEmpty) return const Success(null);
      final fonts = <String, Uint8List>{};
      final now = DateTime.now().microsecondsSinceEpoch.toString();
      for (final file in files) {
        final name = 'custom:$now/${path.basenameWithoutExtension(file.name)}';
        final bytes = await file.readAsBytes();
        await _loadFont(bytes, name);
        fonts[name] = bytes;
      }
      return Success(fonts);
    } catch (error, stackTrace) {
      return _failure('字体导入失败，请检查文件后重试', error, stackTrace);
    }
  }

  static LoadingState<Set<String>> getFont() {
    if (_initialized) return Success(Set.of(_fonts));
    try {
      _fonts.clear();
      final success = switch (defaultTargetPlatform) {
        .android => _initAndroid(),
        .windows => _initWindows(),
        _ => true,
      };
      if (!success) throw StateError('系统字体枚举未完成');
      _initialized = true;
      return Success(Set.of(_fonts));
    } catch (error, stackTrace) {
      _fonts.clear();
      return _failure('加载系统字体失败，请重试', error, stackTrace);
    }
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

// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:get/get_rx/get_rx.dart';
import 'package:media_kit/ffi/src/allocation.dart';
import 'package:media_kit/ffi/src/utf8.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/core/initializer.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';

class MpvConvertWebp {
  final _mpv = NativePlayer.mpv;
  Pointer<generated.mpv_handle> _ctx = nullptr;
  final _completer = Completer<bool>();
  Future<void>? _initialization;
  Future<bool>? _conversion;
  Future<void>? _cleanup;
  bool _disposed = false;

  bool _success = false;

  final String url;
  final String outFile;
  final double start;
  final double duration;
  final RxDouble? progress;
  final WebpPreset preset;

  MpvConvertWebp(
    this.url,
    this.outFile,
    this.start,
    double end, {
    this.progress,
    this.preset = WebpPreset.def,
  }) : duration = end - start;

  Future<void> _init() async {
    final enableHA = Pref.enableHA;
    _ctx = await Initializer.create(
      _mpv,
      _onEvent,
      options: {
        'idle': 'once',
        'o': outFile,
        'start': start.toStringAsFixed(3),
        'end': (start + duration).toStringAsFixed(3),
        'of': 'webp',
        'ovc': 'libwebp_anim',
        'ofopts': 'loop=0',
        'ovcopts': 'preset=${preset.flag}',
        if (enableHA) 'vo': 'gpu',
        if (enableHA) 'hwdec': '${Pref.hardwareDecoding},auto-copy', // transcode only support copy
      },
    );
    if (_disposed) return;
    _mpv.mpv_request_event(
      _ctx,
      generated.mpv_event_id.MPV_EVENT_VIDEO_RECONFIG,
      0,
    );
    NativePlayer.setHeader(
      _mpv,
      _ctx,
      userAgent: BrowserUa.pc,
      referer: HttpString.baseUrl,
    );
    if (progress != null) {
      _observeProperty('time-pos');
    }
    final level = (kDebugMode ? 'info' : 'error').toNativeUtf8();
    _mpv.mpv_request_log_messages(_ctx, level);
    calloc.free(level);
  }

  Future<void> dispose() => _finish(false);

  Future<void> _finish(bool success) {
    _disposed = true;
    return _cleanup ??= _release(success);
  }

  Future<void> _release(bool success) async {
    // SHUTDOWN 回调先归还借用事件，reader 退出后才能释放句柄。
    await Future<void>.delayed(Duration.zero);
    try {
      try {
        await _initialization;
      } catch (_) {
        // 初始化异常交给 convert；已创建的句柄仍需回收。
        success = false;
      }
      if (_ctx != nullptr) {
        await Initializer.dispose(_ctx);
        final address = _ctx.address;
        await _destroyHandle(address, NativeLibrary.path);
        _ctx = nullptr;
      }
      if (!_completer.isCompleted) _completer.complete(success);
    } catch (error, stack) {
      logger.e('WebP 转换资源回收失败', error: error, stackTrace: stack);
      if (!_completer.isCompleted) _completer.complete(false);
    }
  }

  static Future<void> _destroyHandle(int address, String library) =>
      Isolate.run(
        () => generated
            .MPV(DynamicLibrary.open(library))
            .mpv_terminate_destroy(
              Pointer<generated.mpv_handle>.fromAddress(address),
            ),
      );

  Future<bool> convert() => _conversion ??= _convert();

  Future<bool> _convert() async {
    if (_disposed) return false;
    try {
      await (_initialization ??= _init());
      if (!_disposed) _command(['loadfile', url]);
      return await _completer.future;
    } catch (_) {
      final cancelled = _disposed;
      await dispose();
      if (cancelled) return false;
      rethrow;
    }
  }

  Future<void>? _onEvent(Pointer<generated.mpv_event> event) {
    if (_disposed) return null;
    switch (event.ref.event_id) {
      case generated.mpv_event_id.MPV_EVENT_PROPERTY_CHANGE:
        final prop = event.ref.data.cast<generated.mpv_event_property>().ref;
        if (prop.name.toDartString() == 'time-pos' &&
            prop.format == generated.mpv_format.MPV_FORMAT_DOUBLE) {
          progress!.value = (prop.data.cast<Double>().value - start) / duration;
        }
        break;
      case generated.mpv_event_id.MPV_EVENT_FILE_LOADED:
        _success = true;
        break;
      case generated.mpv_event_id.MPV_EVENT_LOG_MESSAGE:
        final log = event.ref.data.cast<generated.mpv_event_log_message>().ref;
        final prefix = log.prefix.toDartString().trim();
        final level = log.level.toDartString().trim();
        final text = log.text.toDartString().trim();
        logger.d('WebpConvert: $level $prefix : $text');
        if (kDebugMode) {
          if (level == 'error' || level == 'fatal') _success = false;
        } else {
          _success = false;
        }
        break;
      case generated.mpv_event_id.MPV_EVENT_SHUTDOWN:
        progress?.value = 1;
        unawaited(_finish(_success));
        break;
    }
    return null;
  }

  void _command(List<String> args) {
    final pointers = args.map((e) => e.toNativeUtf8()).toList();
    final arr = calloc<Pointer<Uint8>>(pointers.length + 1);
    for (int i = 0; i < args.length; i++) {
      arr[i] = pointers[i];
    }

    try {
      final result = _mpv.mpv_command(_ctx, arr);
      if (result < 0) {
        throw StateError(_mpv.mpv_error_string(result).toDartString());
      }
    } finally {
      calloc.free(arr);
      pointers.forEach(calloc.free);
    }
  }

  void _observeProperty(String property) {
    final name = property.toNativeUtf8();
    _mpv.mpv_observe_property(
      _ctx,
      property.hashCode,
      name,
      generated.mpv_format.MPV_FORMAT_DOUBLE,
    );

    calloc.free(name);
  }
}

enum WebpPreset {
  none('none', '无', '不使用预设'),
  def('default', '默认', '默认预设'),
  picture('picture', '图片', '数码照片，如人像、室内拍摄'),
  photo('photo', '照片', '户外摄影，自然光环境'),
  drawing('drawing', '绘图', '手绘或线稿，高对比度细节'),
  icon('icon', '图标', '小型彩色图像'),
  text('text', '文本', '文字类'),
  ;

  final String flag;
  final String name;
  final String desc;

  const WebpPreset(this.flag, this.name, this.desc);
}

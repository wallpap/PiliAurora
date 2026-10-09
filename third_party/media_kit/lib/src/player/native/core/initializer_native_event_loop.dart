/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart';

import 'event_loop_session.dart';
import 'native_event_loop_api.dart';

/// Adapts either native event-loop ABI without reusing borrowed event pointers.
abstract class InitializerNativeEventLoop {
  static NativeEventLoopApi _initializeApi() {
    final DynamicLibrary library;
    try {
      library = DynamicLibrary.open(
        Platform.isMacOS || Platform.isIOS
            ? 'media_kit_native_event_loop.framework/media_kit_native_event_loop'
            : Platform.isAndroid || Platform.isLinux
            ? 'libmedia_kit_native_event_loop.so'
            : Platform.isWindows
            ? 'media_kit_native_event_loop.dll'
            : throw UnsupportedError('Native event-loop platform'),
      );
    } on ArgumentError {
      throw UnsupportedError('Native event-loop library is unavailable');
    }
    // All symbols are validated before calling initialize or allocating mpv.
    final api = NativeEventLoopApi(library);
    api.initialize(NativeApi.postCObject.cast(), _receiver.sendPort.nativePort);
    _receiver.listen(_onMessage);
    return api;
  }

  static Pointer<mpv_handle> create(
    MPV mpv,
    FutureOr<void> Function(Pointer<mpv_event>)? callback,
    Map<String, String> options,
  ) {
    final api = callback == null ? null : _api;
    final handle = mpv.mpv_create();
    if (handle == nullptr) throw StateError('mpv_create returned null');
    try {
      for (final entry in options.entries) {
        final name = entry.key.toNativeUtf8();
        final value = entry.value.toNativeUtf8();
        try {
          mpv.mpv_set_option_string(handle, name, value);
        } finally {
          calloc.free(name);
          calloc.free(value);
        }
      }
      final status = mpv.mpv_initialize(handle);
      if (status < 0) throw StateError('mpv_initialize failed ($status)');
      if (callback != null) {
        late final EventLoopSession<Pointer<mpv_event>?> session;
        session = EventLoopSession(
          onEvent: (event) async {
            if (event != null) {
              // Register API: the C++ reader owns mpv_wait_event. Its posted
              // pointer must be acknowledged only after the callback returns.
              await callback(event);
            } else {
              // Callback ABI: only this serial Dart drain calls mpv_wait_event.
              while (!session.closing) {
                final next = mpv.mpv_wait_event(handle, 0);
                if (next.ref.event_id == mpv_event_id.MPV_EVENT_NONE) break;
                await callback(next);
              }
            }
          },
          acknowledge: () => api!.acknowledge(handle.address),
          shutdown: () => api!.dispose(mpv, handle),
          onError: (error, stack) =>
              Zone.current.handleUncaughtError(error, stack),
        );
        _sessions[handle.address] = session;
        api!.register(
          mpv,
          handle,
          NativeApi.postCObject.cast(),
          _receiver.sendPort.nativePort,
        );
      }
      return handle;
    } catch (_) {
      _sessions.remove(handle.address);
      mpv.mpv_terminate_destroy(handle);
      rethrow;
    }
  }

  static void _onMessage(dynamic message) {
    final int address;
    final Pointer<mpv_event>? event;
    if (message is List &&
        message.length == 2 &&
        message[0] is int &&
        message[1] is int) {
      address = message[0] as int;
      event = Pointer.fromAddress(message[1] as int);
    } else if (message is int) {
      address = message;
      event = null;
    } else {
      return;
    }
    _sessions[address]?.add(event);
  }

  static Future<void> dispose(Pointer<mpv_handle> handle) async {
    final session = _sessions[handle.address];
    if (session == null) return;
    await session.stop();
    if (identical(_sessions[handle.address], session)) {
      _sessions.remove(handle.address);
    }
  }

  static final _receiver = ReceivePort();
  static final _api = _initializeApi();
  static final _sessions = <int, EventLoopSession<Pointer<mpv_event>?>>{};
}

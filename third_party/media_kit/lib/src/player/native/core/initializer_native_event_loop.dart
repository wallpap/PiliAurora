/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:ffi';
import 'dart:async';
import 'dart:isolate';
import 'dart:collection';

import 'package:media_kit/ffi/ffi.dart';

import 'package:media_kit/generated/libmpv/bindings.dart';
import 'package:media_kit/src/player/native/player/real.dart';

/// InitializerNativeEventLoop
/// --------------------------
///
/// Creates & returns initialized [Pointer<mpv_handle>] whose event loop is running on native thread.
///
/// See:
/// * https://github.com/media-kit/media-kit/issues/40
/// * https://github.com/media-kit/media-kit/pull/46
/// * https://github.com/dart-lang/sdk/issues/51254
/// * https://github.com/dart-lang/sdk/issues/51261
///
abstract class InitializerNativeEventLoop {
  /// Initializes the |InitializerNativeEventLoop| class for usage.
  @pragma('vm:prefer-inline')
  static Pointer<NativeFunction<MediaKitEventLoopHandlerCallback>>
  _initHandle() {
    final dylib = DynamicLibrary.open(
      Platform.isMacOS || Platform.isIOS
          ? 'media_kit_native_event_loop.framework/media_kit_native_event_loop'
          : Platform.isAndroid || Platform.isLinux
          ? 'libmedia_kit_native_event_loop.so'
          : Platform.isWindows
          ? 'media_kit_native_event_loop.dll'
          : throw UnimplementedError(),
    );

    dylib.lookupFunction<
      MediaKitEventLoopHandlerInitializeCXX,
      MediaKitEventLoopHandlerInitializeDart
    >('MediaKitEventLoopHandlerInitialize')(
      NativeApi.postCObject,
      _receiver.sendPort.nativePort,
    );

    final handle = dylib
        .lookup<NativeFunction<MediaKitEventLoopHandlerCallback>>(
          'MediaKitEventLoopHandlerCallback',
        );
    _handleWakeup();
    return handle;
  }

  /// Creates & returns initialized [Pointer<mpv_handle>] whose event loop is running on native thread.
  static Pointer<mpv_handle> create(
    MPV mpv,
    FutureOr<void> Function(Pointer<mpv_event> event)? callback,
    Map<String, String> options,
  ) {
    // Native functions from the shared library should be resolved by now. If not, throw an exception.
    // Primarily, this will happen when the shared library is not found i.e. package:media_kit_native_event_loop is not installed.

    // Create [mpv_handle] & initialize it.
    final handle = mpv.mpv_create();

    // Set custom defined options before [mpv_initialize].
    for (final entry in options.entries) {
      final name = entry.key.toNativeUtf8();
      final value = entry.value.toNativeUtf8();
      mpv.mpv_set_option_string(handle, name, value);
      calloc.free(name);
      calloc.free(value);
    }

    mpv.mpv_initialize(handle);

    // Only register for event callbacks if [callback] is not null.
    if (callback != null) {
      // Save [callback] to invoke it inside [ReceivePort] listener.
      _callbacks[handle.address] = callback;
      // Register event callback.
      mpv.mpv_set_wakeup_callback(handle, _handle, handle.cast());
    }

    return handle;
  }

  /// Disposes the event loop of the [Pointer<mpv_handle>] created by [create].
  /// NOTE: [Pointer<mpv_handle>] itself is not disposed.
  static void dispose(Pointer<mpv_handle> handle) {
    // Native functions from the shared library should be resolved by now. If not, throw an exception.
    // Primarily, this will happen when the shared library is not found i.e. package:media_kit_native_event_loop is not installed.

    NativePlayer.mpv.mpv_set_wakeup_callback(handle, nullptr, nullptr);
    _callbacks.remove(handle.address);
  }

  /// [ReceivePort] used to listen for `mpv_set_wakeup_callback` from the native event loop.
  static final _receiver = ReceivePort();

  static Future<void> _handleWakeup() async {
    await for (final int handle in _receiver) {
      final callback = _callbacks[handle];
      if (callback == null) continue;

      final ctx = Pointer<mpv_handle>.fromAddress(handle);
      while (await Future.microtask(() async {
        final event = NativePlayer.mpv.mpv_wait_event(ctx, 0);
        if (event.ref.event_id == mpv_event_id.MPV_EVENT_NONE) return false;
        try {
          await callback(event);
        } catch (error, stackTrace) {
          Zone.current.handleUncaughtError(error, stackTrace);
        }
        return _callbacks.containsKey(handle);
      })) {}
    }
  }

  // Registered [callback]s to receive [mpv_event](s) from the native event loop.
  static final _callbacks =
      HashMap<int, FutureOr<void> Function(Pointer<mpv_event>)>();
  static final _handle = _initHandle();
}

// Type definitions for native functions in the shared library.

// C/C++:

typedef MediaKitEventLoopHandlerInitializeCXX =
    Void Function(
      Pointer<NativeFunction<Int8 Function(Int64, Pointer<Dart_CObject>)>>
      callback,
      Int64 port,
    );
typedef MediaKitEventLoopHandlerCallback = Void Function(Pointer<Void> context);

// Dart:

typedef MediaKitEventLoopHandlerInitializeDart =
    void Function(
      Pointer<NativeFunction<Int8 Function(Int64, Pointer<Dart_CObject>)>>
      callback,
      int port,
    );

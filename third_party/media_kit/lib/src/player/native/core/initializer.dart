/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:ffi';

import 'event_loop_lifecycle.dart';
import 'initializer_isolate.dart';
import 'initializer_native_event_loop.dart';

import 'package:media_kit/generated/libmpv/bindings.dart';

/// Creates & returns initialized [Pointer<mpv_handle>].
/// Pass [path] to libmpv dynamic library & [callback] to receive event callbacks as [Pointer<mpv_event>].
///
/// Optionally, [options] may be passed to set libmpv options before the initialization.
///
/// Platform specific threaded event loop is preferred over [Isolate] based event loop (automatic fallback).
/// See package:media_kit_native_event_loop for more details.
abstract class Initializer {
  /// Creates & returns initialized [Pointer<mpv_handle>].
  static FutureOr<Pointer<mpv_handle>> create(
    MPV mpv,
    FutureOr<void> Function(Pointer<mpv_event> event)? callback, {
    Map<String, String> options = const {},
  }) {
    return _loops.create(
      nativeCreate: () =>
          InitializerNativeEventLoop.create(mpv, callback, options),
      isolateCreate: () => InitializerIsolate.create(mpv, callback, options),
    );
  }

  /// Disposes the event loop of the [Pointer<mpv_handle>] created by [create].
  /// NOTE: [Pointer<mpv_handle>] itself is not disposed.
  static Future<void> dispose(Pointer<mpv_handle> handle) =>
      _loops.dispose(handle);

  static final _loops = EventLoopLifecycle<Pointer<mpv_handle>>(
    handleId: (handle) => handle.address,
    nativeDispose: InitializerNativeEventLoop.dispose,
    isolateDispose: InitializerIsolate.dispose,
    onNativeFailure: (error, stack) {
      // An optional library/ABI miss is an expected backend selection, not an
      // uncaught application failure. Real initialization errors remain visible.
      if (error is! UnsupportedError) {
        Zone.current.handleUncaughtError(error, stack);
      }
    },
  );
}

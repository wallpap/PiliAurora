/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';

import 'event_loop_session.dart';

/// Isolate fallback with an explicit reader-exit acknowledgement.
abstract class InitializerIsolate {
  static Future<Pointer<mpv_handle>> create(
    MPV mpv,
    FutureOr<void> Function(Pointer<mpv_event>)? callback,
    Map<String, String> options,
  ) async {
    if (callback == null) {
      return _createHandle(mpv, options);
    }
    final initialized = Completer<Pointer<mpv_handle>>();
    final exited = Completer<void>();
    final receiver = ReceivePort();
    final exitReceiver = ReceivePort();
    final errorReceiver = ReceivePort();
    SendPort? worker;
    EventLoopSession<Pointer<mpv_event>>? session;

    exitReceiver.listen((_) {
      if (!exited.isCompleted) exited.complete();
      if (!initialized.isCompleted) {
        initialized.completeError(
          StateError('mpv event isolate exited during initialization'),
        );
      }
      exitReceiver.close();
      errorReceiver.close();
    });
    errorReceiver.listen((message) {
      final error = StateError(
        'mpv event isolate failed: ${message is List ? message.first : message}',
      );
      if (!initialized.isCompleted) {
        initialized.completeError(error);
      } else {
        Zone.current.handleUncaughtError(error, StackTrace.current);
      }
    });
    receiver.listen((dynamic message) {
      if (message is SendPort) {
        worker = message;
        worker!.send(options);
        worker!.send(NativeLibrary.path);
      } else if (message is int && !initialized.isCompleted) {
        final handle = Pointer<mpv_handle>.fromAddress(message);
        session = EventLoopSession(
          onEvent: callback,
          acknowledge: () => worker!.send(true),
          shutdown: () async {
            worker!.send(null);
            // A message cannot interrupt a blocking FFI wait. Wake it from
            // the owner isolate, then wait for actual exit before destruction.
            mpv.mpv_wakeup(handle);
            await exited.future;
            receiver.close();
          },
          onError: (error, stack) =>
              Zone.current.handleUncaughtError(error, stack),
        );
        _sessions[handle.address] = session!;
        initialized.complete(handle);
      } else if (message is int) {
        session?.add(Pointer<mpv_event>.fromAddress(message));
      }
    });
    try {
      await Isolate.spawn(
        _mainloop,
        receiver.sendPort,
        onExit: exitReceiver.sendPort,
        onError: errorReceiver.sendPort,
        errorsAreFatal: true,
      );
      return await initialized.future;
    } catch (_) {
      receiver.close();
      exitReceiver.close();
      errorReceiver.close();
      rethrow;
    }
  }

  static Pointer<mpv_handle> _createHandle(
    MPV mpv,
    Map<String, String> options,
  ) {
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
      return handle;
    } catch (_) {
      mpv.mpv_terminate_destroy(handle);
      rethrow;
    }
  }

  static Future<void> dispose(Pointer<mpv_handle> handle) async {
    final session = _sessions[handle.address];
    if (session == null) return;
    await session.stop();
    if (identical(_sessions[handle.address], session)) {
      _sessions.remove(handle.address);
    }
  }

  static Future<void> _mainloop(SendPort port) async {
    final configured = Completer<void>();
    final receiver = ReceivePort();
    port.send(receiver.sendPort);
    late Map<String, String> options;
    late MPV mpv;
    Completer<void>? acknowledged;
    bool disposed = false;

    receiver.listen((dynamic message) {
      if (message is Map<String, String>) {
        options = message;
      } else if (message is String) {
        mpv = MPV(DynamicLibrary.open(message));
        configured.complete();
      } else if (message is bool) {
        if (!(acknowledged?.isCompleted ?? true)) acknowledged!.complete();
      } else if (message == null) {
        disposed = true;
        if (!(acknowledged?.isCompleted ?? true)) acknowledged!.complete();
      }
    });
    await configured.future;
    final handle = _createHandle(mpv, options);
    port.send(handle.address);
    try {
      while (!disposed) {
        // Let queued disposal messages run before entering another blocking
        // FFI wait. Never invalidate a borrowed event before Dart acknowledges it.
        await Future<void>.delayed(Duration.zero);
        if (disposed) break;
        final event = mpv.mpv_wait_event(handle, -1);
        if (event.ref.event_id != mpv_event_id.MPV_EVENT_NONE) {
          acknowledged = Completer<void>();
          port.send(event.address);
          await acknowledged.future;
        }
      }
    } finally {
      receiver.close();
    }
  }

  static final _sessions = <int, EventLoopSession<Pointer<mpv_event>>>{};
}

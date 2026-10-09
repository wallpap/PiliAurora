import 'dart:ffi';

import 'package:media_kit/generated/libmpv/bindings.dart';

enum NativeEventLoopAbi { registeredEvents, wakeupCallback }

/// Resolve the complete ABI before initializing a library or allocating mpv.
/// 1.0.9 exports Register/Notify/Dispose and posts [handle,event] pairs. Older
/// builds export Callback and post only a handle for Dart-side event polling.
NativeEventLoopAbi resolveNativeEventLoopAbi(bool Function(String) provides) {
  if (provides('MediaKitEventLoopHandlerCallback')) {
    if (provides('MediaKitEventLoopHandlerInitialize')) {
      return NativeEventLoopAbi.wakeupCallback;
    }
  } else if (const [
    'MediaKitEventLoopHandlerInitialize',
    'MediaKitEventLoopHandlerRegister',
    'MediaKitEventLoopHandlerNotify',
    'MediaKitEventLoopHandlerDispose',
  ].every(provides)) {
    return NativeEventLoopAbi.registeredEvents;
  }
  throw UnsupportedError('Unsupported native event-loop ABI');
}

class NativeEventLoopApi {
  NativeEventLoopApi(DynamicLibrary library)
    : abi = resolveNativeEventLoopAbi(library.providesSymbol) {
    if (abi == NativeEventLoopAbi.registeredEvents) {
      final initialize = library
          .lookupFunction<Void Function(), void Function()>(
            'MediaKitEventLoopHandlerInitialize',
          );
      _initialize = (_, _) => initialize();
      _register = library
          .lookupFunction<
            Void Function(Int64, Pointer<Void>, Int64),
            void Function(int, Pointer<Void>, int)
          >('MediaKitEventLoopHandlerRegister');
      _notify = library
          .lookupFunction<Void Function(Int64), void Function(int)>(
            'MediaKitEventLoopHandlerNotify',
          );
      _dispose = library
          .lookupFunction<Void Function(Int64), void Function(int)>(
            'MediaKitEventLoopHandlerDispose',
          );
    } else {
      _callback = library.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
        'MediaKitEventLoopHandlerCallback',
      );
      _initialize = library
          .lookupFunction<
            Void Function(Pointer<Void>, Int64),
            void Function(Pointer<Void>, int)
          >('MediaKitEventLoopHandlerInitialize');
    }
  }

  final NativeEventLoopAbi abi;
  late final void Function(Pointer<Void>, int) _initialize;
  void Function(int, Pointer<Void>, int)? _register;
  void Function(int)? _notify;
  void Function(int)? _dispose;
  Pointer<NativeFunction<Void Function(Pointer<Void>)>>? _callback;

  void initialize(Pointer<Void> postCObject, int port) =>
      _initialize(postCObject, port);

  void register(
    MPV mpv,
    Pointer<mpv_handle> handle,
    Pointer<Void> post,
    int port,
  ) {
    if (abi == NativeEventLoopAbi.registeredEvents) {
      _register!(handle.address, post, port);
    } else {
      mpv.mpv_set_wakeup_callback(handle, _callback!, handle.cast());
    }
  }

  void acknowledge(int handle) => _notify?.call(handle);

  void dispose(MPV mpv, Pointer<mpv_handle> handle) {
    if (abi == NativeEventLoopAbi.registeredEvents) {
      _dispose!(handle.address); // Joins the native reader before returning.
    } else {
      mpv.mpv_set_wakeup_callback(handle, nullptr, nullptr);
    }
  }
}

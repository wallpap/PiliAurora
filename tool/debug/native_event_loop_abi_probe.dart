// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:media_kit/generated/libmpv/bindings.dart';
import 'package:media_kit/src/player/native/core/initializer_isolate.dart';
import 'package:media_kit/src/player/native/core/native_event_loop_api.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';

// Opens only the caller-specified mock DLLs, never installed player libraries.
void check(bool value, String message) {
  if (!value) throw StateError('FAIL: $message');
  print('PASS: $message');
}

Future<void> main(List<String> args) async {
  if (args.length != 2 ||
      args.any((p) => !File(p).absolute.path.endsWith('_mock.dll'))) {
    throw ArgumentError(
      'Pass registered_mock.dll and legacy_mock.dll fixture paths',
    );
  }
  for (final index in [0, 1]) {
    final library = DynamicLibrary.open(File(args[index]).absolute.path);
    final read = library.lookupFunction<Int Function(Int), int Function(int)>(
      'MockState',
    );
    final api = NativeEventLoopApi(library);
    final mpv = MPV(library);
    check(
      api.abi ==
          (index == 0
              ? NativeEventLoopAbi.registeredEvents
              : NativeEventLoopAbi.wakeupCallback),
      '${index == 0 ? "registered" : "legacy"} complete ABI resolves',
    );
    api.initialize(NativeApi.postCObject.cast(), 123);
    api.register(
      mpv,
      Pointer<mpv_handle>.fromAddress(42),
      NativeApi.postCObject.cast(),
      123,
    );
    api.acknowledge(42);
    api.dispose(mpv, Pointer<mpv_handle>.fromAddress(42));
    check(
      read(0) == 1 &&
          (index == 0
              ? read(2) == 1 && read(3) == 1 && read(6) == 1 && read(7) == 1
              : read(1) == 1 && read(4) == 1 && read(5) == 1),
      '${index == 0 ? "registered" : "legacy"} FFI signatures and acknowledgements match',
    );
  }
  final path = File(args[0]).absolute.path;
  final library = DynamicLibrary.open(path);
  final mpv = MPV(library);
  final read = library.lookupFunction<Int Function(Int), int Function(int)>(
    'MockState',
  );
  NativeLibrary.ensureInitialized(libmpv: path);
  final entered = Completer<void>();
  final release = Completer<void>();
  final handle = await InitializerIsolate.create(mpv, (event) async {
    check(
      event.ref.event_id == mpv_event_id.MPV_EVENT_LOG_MESSAGE,
      'actual isolate adapter delivers the fixture event',
    );
    entered.complete();
    await release.future;
    check(
      event.ref.reply_userdata == 123,
      'borrowed pointer survives the asynchronous callback',
    );
  }, {'vid': 'no'});
  await entered.future.timeout(const Duration(seconds: 5));
  var stopped = false;
  final stop = InitializerIsolate.dispose(handle).then((_) => stopped = true);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  check(
    !stopped && read(9) == 0,
    'actual isolate stop cannot destroy a handle during its callback',
  );
  release.complete();
  await stop.timeout(const Duration(seconds: 5));
  mpv.mpv_terminate_destroy(handle);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  check(
    stopped && read(8) == 1 && read(9) == 1 && read(12) == 0,
    'actual isolate reader exits before mock mpv destruction, with no stale reads',
  );
}

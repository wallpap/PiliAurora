// ignore_for_file: avoid_print, cascade_invocations

import 'dart:async';

import 'package:media_kit/src/player/native/core/event_loop_lifecycle.dart';
import 'package:media_kit/src/player/native/core/event_loop_session.dart';
import 'package:media_kit/src/player/native/core/native_event_loop_api.dart';

// Pure Dart only: no Player, Flutter engine or dynamic library is instantiated.
void check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
  print('PASS: $message');
}

Future<void> main() async {
  var nativeDisposals = 0;
  var isolateDisposals = 0;
  final failures = <Object>[];
  final loops = EventLoopLifecycle<int>(
    handleId: (value) => value,
    nativeDispose: (_) => nativeDisposals++,
    isolateDispose: (_) => isolateDisposals++,
    onNativeFailure: (error, _) => failures.add(error),
  );
  final handle = await loops.create(
    nativeCreate: () =>
        throw UnsupportedError('Missing native wakeup callback ABI'),
    isolateCreate: () => 42,
  );
  await loops.dispose(handle);
  check(
    nativeDisposals == 0 && isolateDisposals == 1,
    'fallback handle stops its actual isolate backend',
  );
  await loops.dispose(handle);
  check(isolateDisposals == 1, 'duplicate stop is harmless');
  final native = await loops.create(
    nativeCreate: () => 43,
    isolateCreate: () => 99,
  );
  await loops.dispose(native);
  check(
    nativeDisposals == 1 && isolateDisposals == 1,
    'native handle stops only the native backend',
  );

  final stopGate = Completer<void>();
  var stops = 0;
  final asyncLoops = EventLoopLifecycle<int>(
    handleId: (value) => value,
    nativeDispose: (_) {
      stops++;
      return stopGate.future;
    },
    isolateDispose: (_) {},
    onNativeFailure: (_, _) {},
  );
  await asyncLoops.create(nativeCreate: () => 44, isolateCreate: () => 99);
  var completed = false;
  final stop = asyncLoops.dispose(44).then((_) => completed = true);
  final duplicate = asyncLoops.dispose(44);
  await Future<void>.delayed(Duration.zero);
  check(
    !completed && stops == 1,
    'stop waits for reader exit and is not started twice',
  );
  stopGate.complete();
  await stop;
  await duplicate;
  check(completed, 'reader exit releases the handle owner');

  final currentSymbols = {
    'MediaKitEventLoopHandlerInitialize',
    'MediaKitEventLoopHandlerRegister',
    'MediaKitEventLoopHandlerNotify',
    'MediaKitEventLoopHandlerDispose',
  };
  check(
    resolveNativeEventLoopAbi(currentSymbols.contains) ==
        NativeEventLoopAbi.registeredEvents,
    '1.0.9 Register/Notify/Dispose ABI is supported without Callback',
  );
  final legacySymbols = {
    'MediaKitEventLoopHandlerInitialize',
    'MediaKitEventLoopHandlerCallback',
  };
  check(
    resolveNativeEventLoopAbi(legacySymbols.contains) ==
        NativeEventLoopAbi.wakeupCallback,
    'legacy wakeup callback ABI remains supported',
  );
  currentSymbols.remove('MediaKitEventLoopHandlerNotify');
  var rejected = false;
  try {
    resolveNativeEventLoopAbi(currentSymbols.contains);
  } on UnsupportedError {
    rejected = true;
  }
  check(rejected, 'incomplete ABI is rejected before mpv allocation');

  final eventGate = Completer<void>();
  final readStarted = Completer<void>();
  final events = <String>[];
  final session = EventLoopSession<int>(
    onEvent: (_) async {
      events.add('read');
      readStarted.complete();
      await eventGate.future;
    },
    acknowledge: () => events.add('ack'),
    shutdown: () => events.add('join'),
    onError: (_, _) => events.add('error'),
  );
  session.add(1);
  await readStarted.future;
  final closing = session.stop();
  await Future<void>.delayed(Duration.zero);
  check(
    events.join(',') == 'read',
    'borrowed event prevents early ack and teardown',
  );
  eventGate.complete();
  await closing;
  check(
    events.join(',') == 'read,ack,join',
    'read finishes before ack and reader join',
  );
  session.add(2);
  await session.stop();
  check(
    events.length == 3,
    'late event and repeated stop cannot touch a stopped reader',
  );

  final failed = <String>[];
  final broken = EventLoopSession<int>(
    onEvent: (_) => throw StateError('mock parser failure'),
    acknowledge: () => failed.add('ack'),
    shutdown: () => failed.add('join'),
    onError: (_, _) => failed.add('error'),
  );
  broken.add(1);
  await Future<void>.delayed(Duration.zero);
  await broken.stop();
  check(
    failed.join(',') == 'error,ack,join',
    'parse failure still acknowledges and releases reader',
  );
}

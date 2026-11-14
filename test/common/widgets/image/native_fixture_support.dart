import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/src/native_worker_backend.dart';

final nativeWorker =
    Platform.environment['REGION_TEST_WORKER'] ??
    'build/probes/image-region/native/Release/piliaurora_image_worker.exe';
final nativeFixtureFile = File(
  Platform.environment['REGION_FIXTURES'] ??
      'build/probes/image-region/fixtures.json',
);
final nativeFixtureAvailable =
    Platform.isWindows &&
    File(nativeWorker).existsSync() &&
    nativeFixtureFile.existsSync();
final nativeFixtures = nativeFixtureAvailable
    ? ((jsonDecode(nativeFixtureFile.readAsStringSync()) as Map)['images']
              as List)
          .cast<Map>()
    : <Map>[];
final nativeWorkerEvents = <Map<String, Object?>>[];

void observeNativeWorkers() {
  setUp(() {
    nativeWorkerEvents.clear();
    NativeWorkerDecoder.onEvent = nativeWorkerEvents.add;
  });
  tearDown(() => NativeWorkerDecoder.onEvent = null);
}

const _skipReason =
    'Windows worker fixtures required: python tool/probes/windows/image_region_probe.py';

void nativeTest(String description, FutureOr<void> Function() body) => test(
  description,
  () => NativeWorkerDecoder.runWith(nativeWorker, body),
  skip: nativeFixtureAvailable ? false : _skipReason,
);

void nativeTestWidgets(String description, WidgetTesterCallback body) =>
    testWidgets(
      description,
      (tester) => NativeWorkerDecoder.runWith(nativeWorker, () => body(tester)),
      skip: !nativeFixtureAvailable,
    );

// 本地探针复用Flutter工具链已解析的vm_service，不增加应用依赖。
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// 认证URI经stdin传入，不出现在命令行/输出中；只采指定测试进程。
Future<void> main() async {
  VmService? service;
  StreamSubscription<Event>? subscription;
  IOSink? sink;
  try {
    final input = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
    final uri = Uri.parse(input['uri'] as String);
    if (!['127.0.0.1', 'localhost', '::1'].contains(uri.host)) {
      throw ArgumentError('loopback only');
    }
    service = await vmServiceConnectUri(
      uri.replace(scheme: 'ws', path: '${uri.path}ws').toString(),
    ).timeout(const Duration(seconds: 15));
    final vm = await service.getVM().timeout(const Duration(seconds: 15));
    if (vm.pid != input['pid']) throw StateError('PID mismatch');
    final id = input['isolateId'] as String;
    final output = File(input['output'] as String);
    await output.create(exclusive: true);
    sink = output.openWrite();
    final completed = Completer<void>();
    var bytes = 0;
    await service.streamListen(EventStreams.kHeapSnapshot);
    subscription = service.onHeapSnapshotEvent.listen(
      (event) {
        if (event.isolate?.id != null && event.isolate!.id != id) return;
        final data = event.data;
        if (data != null) {
          final chunk = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
          sink!.add(chunk);
          bytes += chunk.length;
        }
        if (event.last == true && !completed.isCompleted) completed.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (!completed.isCompleted) completed.completeError(error, stack);
      },
    );
    await service.requestHeapSnapshot(id).timeout(const Duration(seconds: 15));
    await completed.future.timeout(const Duration(seconds: 120));
    await sink.flush();
    await sink.close();
    sink = null;
    stdout.writeln(
      jsonEncode({
        'status': 'saved',
        'bytes': bytes,
        'format': 'DartHeapSnapshot',
        'scope': 'localOnly; mayContainObjectData',
      }),
    );
  } catch (error) {
    stdout.writeln(
      jsonEncode({
        'status': 'failed',
        'errorType': error.runtimeType.toString(),
      }),
    );
    exitCode = 1;
  } finally {
    await subscription?.cancel();
    await sink?.close();
    await service?.dispose();
  }
}

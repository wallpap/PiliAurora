import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pili_aurora/services/live_stream/live_packet.dart';

/// 每个连接复用一个 worker。关闭时终止 worker，并结束所有在途任务。
class LivePacketDecoder {
  final _pending = <int, Completer<List<DecodedLivePacket>>>{};
  ReceivePort? _responses, _errors, _exits;
  Completer<SendPort>? _bootstrap;
  Isolate? _isolate;
  SendPort? _commands;
  Future<void>? _starting;
  bool _closed = false;
  int _sequence = 0;

  Future<List<DecodedLivePacket>> decode(Uint8List bytes) async {
    if (_closed) throw StateError('直播解析器已关闭');
    await (_starting ??= _start());
    if (_closed) throw StateError('直播解析器已关闭');
    final id = ++_sequence;
    final result = Completer<List<DecodedLivePacket>>();
    _pending[id] = result;
    _commands!.send((id, TransferableTypedData.fromList([bytes])));
    return result.future;
  }

  Future<void> _start() {
    final ready = _bootstrap = Completer<SendPort>();
    final responses = _responses = ReceivePort()
      ..listen((dynamic message) {
        if (_closed) return;
        if (message is SendPort) {
          _commands = message;
          if (!ready.isCompleted) ready.complete(message);
        } else if (message case (int id, List<DecodedLivePacket> packets)) {
          _pending.remove(id)?.complete(packets);
        } else if (message case (int id, String error)) {
          _pending.remove(id)?.completeError(StateError(error));
        }
      });
    final errors = _errors = ReceivePort();
    final exits = _exits = ReceivePort();
    errors.listen((_) => _terminate(StateError('直播解析 worker 异常退出')));
    exits.listen((_) => _terminate(StateError('直播解析 worker 已退出')));
    final spawned =
        Isolate.spawn(
          _worker,
          responses.sendPort,
          debugName: 'live-packet-decoder',
          onError: errors.sendPort,
          onExit: exits.sendPort,
        ).then(
          (isolate) {
            if (_closed) {
              isolate.kill(priority: Isolate.immediate);
            } else {
              _isolate = isolate;
            }
          },
          onError: (Object error, StackTrace stack) {
            _terminate(error, stack);
          },
        );
    return Future.wait<Object?>([spawned, ready.future]).then((_) {});
  }

  void _terminate(Object error, [StackTrace? stack]) {
    if (_closed) return;
    _closed = true;
    final ready = _bootstrap;
    if (ready != null && !ready.isCompleted) ready.completeError(error, stack);
    for (final result in _pending.values) {
      result.completeError(error, stack);
    }
    _pending.clear();
    _responses?.close();
    _errors?.close();
    _exits?.close();
    _commands = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  void close() => _terminate(StateError('直播解析器已关闭'));
}

void _worker(SendPort responses) {
  final requests = ReceivePort();
  responses.send(requests.sendPort);
  requests.listen((dynamic message) {
    if (message case (int id, TransferableTypedData bytes)) {
      try {
        responses.send((
          id,
          decodeLivePackets(bytes.materialize().asUint8List()),
        ));
      } catch (_) {
        responses.send((id, '直播消息解析失败'));
      }
    }
  });
}

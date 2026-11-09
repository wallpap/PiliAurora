import 'dart:async';
import 'dart:collection';
import 'dart:developer' show Timeline;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/services/live_stream/live_packet.dart';
import 'package:pili_aurora/services/live_stream/live_packet_decoder.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

export 'package:pili_aurora/services/live_stream/live_packet.dart'
    show PackageHeader, PackageHeaderRes;

/// 保留协议 Map 形状，同时携带传输入口的本机单调收到时间。
class LiveMessageBody extends MapBase<String, dynamic> {
  LiveMessageBody(this._body, this.receivedAtUs);
  final Map<String, dynamic> _body;
  final int receivedAtUs;
  @override
  dynamic operator [](Object? key) => _body[key];
  @override
  void operator []=(String key, dynamic value) => _body[key] = value;
  @override
  Iterable<String> get keys => _body.keys;
  @override
  void clear() => _body.clear();
  @override
  dynamic remove(Object? key) => _body.remove(key);
}

abstract class Message {
  String toJsonStr();
}

class AuthMessage implements Message {
  int roomid;
  int uid;
  int protover;
  String platform;
  int type;
  String key;

  AuthMessage({
    required this.roomid,
    required this.uid,
    required this.protover,
    required this.platform,
    required this.type,
    required this.key,
  });

  @override
  String toJsonStr() {
    final message = {
      'roomid': roomid,
      'uid': uid,
      'protover': protover,
      'platform': platform,
      'type': type,
      'key': key,
    };
    return jsonEncode(message);
  }
}

abstract class AbstractPackage<T> {
  PackageHeader header;
  T body;
  Uint8List marshal();
  AbstractPackage({required this.header, required this.body});
}

//认证包
class AuthPackage extends AbstractPackage<Message> {
  AuthPackage({required super.header, required super.body});

  @override
  Uint8List marshal() {
    final json = utf8.encode(body.toJsonStr());
    final buffer = BytesBuilder()
      ..add(header.toBytes(json.length))
      ..add(json);
    return buffer.toBytes();
  }
}

//心跳包
class HeartbeatPackage extends AbstractPackage<dynamic> {
  HeartbeatPackage({required super.header, super.body});

  @override
  Uint8List marshal() {
    return header.toBytes(0);
  }
}

enum LiveMessageConnectionOutcome { connected, failed, closed }

class LiveMessageConnectionResult {
  const LiveMessageConnectionResult._(
    this.outcome, {
    this.message,
    this.code,
    this.cause,
    this.stackTrace,
  });
  const LiveMessageConnectionResult.connected()
    : this._(LiveMessageConnectionOutcome.connected);
  const LiveMessageConnectionResult.closed()
    : this._(LiveMessageConnectionOutcome.closed);
  const LiveMessageConnectionResult.failed(
    String message, {
    int? code,
    Object? cause,
    StackTrace? stackTrace,
  }) : this._(
         LiveMessageConnectionOutcome.failed,
         message: message,
         code: code,
         cause: cause,
         stackTrace: stackTrace,
       );

  final LiveMessageConnectionOutcome outcome;
  final String? message;
  final int? code;
  final Object? cause;
  final StackTrace? stackTrace;
}

/// 维护一条直播消息 WebSocket：连接、认证、心跳、拆包并分发消息。
///
/// 页面持有该对象并在离开直播间时调用 [close] 释放连接和解析 worker。
class LiveMessageStream {
  String streamToken;
  int roomId, uid;
  List<String> servers;
  final List<void Function(dynamic obj)> _eventListeners = [];
  LiveMessageStream({
    required this.streamToken,
    required this.roomId,
    required this.uid,
    required this.servers,
    this.heartbeatInterval = const Duration(seconds: 30),
    this.connectionTimeout = const Duration(seconds: 10),
    this.authenticationTimeout = const Duration(seconds: 10),
  });
  final Duration heartbeatInterval;
  final Duration connectionTimeout;
  final Duration authenticationTimeout;
  final _decoder = LivePacketDecoder();

  bool _active = true;
  final _closed = Completer<void>();
  Future<LiveMessageConnectionResult>? _initializing;
  final _authentication = Completer<LiveMessageConnectionResult>();
  LiveMessageConnectionResult? _failure;
  HttpClient? _connectingClient;
  WebSocketChannel? _channel;
  StreamSubscription? _socketSubscription;
  Timer? _timer;
  static const String logTag = "LiveStreamService";

  bool get isActive => _active;

  /// 重入共用初始化；仅收到成功认证回执才返回 connected，关闭与失败均返回明确结果。
  Future<LiveMessageConnectionResult> init() => _initializing ??= _init();

  Future<WebSocketChannel?> _connect() async {
    Object? lastError;
    StackTrace? lastStack;
    for (final server in servers) {
      if (!_active) return null;
      final client = HttpClient();
      _connectingClient = client;
      try {
        final connecting = WebSocket.connect(server, customClient: client).then(
          (socket) {
            // timeout/close 不会取消 Future，迟到的握手也必须释放。
            if (!_active || !identical(_connectingClient, client)) {
              unawaited(socket.close());
              return null;
            }
            return socket;
          },
        );
        final socket = await Future.any<WebSocket?>([
          connecting,
          _closed.future.then((_) => null),
        ]).timeout(connectionTimeout);
        if (socket == null) return null;
        return IOWebSocketChannel(socket);
      } catch (error, stackTrace) {
        if (!_active) return null;
        lastError = error;
        lastStack = stackTrace;
        final uri = Uri.tryParse(server);
        final endpoint = uri == null || uri.host.isEmpty
            ? '<invalid endpoint>'
            : '${uri.host}:${uri.port == 0 ? 'default' : uri.port}';
        logger.w(
          '$logTag websocket connection failed: $endpoint',
          error: error.runtimeType,
          stackTrace: stackTrace,
        );
      } finally {
        _connectingClient = null;
        // 升级完成的 WebSocket 已脱离 HttpClient；这里只终止未完成的 HTTP 握手。
        client.close(force: true);
      }
    }
    if (lastError != null) Error.throwWithStackTrace(lastError, lastStack!);
    throw StateError('未提供直播消息节点');
  }

  Future<LiveMessageConnectionResult> _init() async {
    if (!_active) return _failure ?? const LiveMessageConnectionResult.closed();
    final authPackage = AuthPackage(
      header: const PackageHeader(
        protocolVer: 1,
        operationCode: 7,
        seq: 1,
      ),
      body: AuthMessage(
        roomid: roomId,
        uid: uid,
        protover: 3,
        platform: 'web',
        type: 2,
        key: streamToken,
      ),
    );

    try {
      final channel = await _connect();
      if (channel == null) {
        return _failure ?? const LiveMessageConnectionResult.closed();
      }
      if (!_active) {
        if (kDebugMode) logger.i("$logTag init inactive $hashCode");
        await channel.sink.close();
        return _failure ?? const LiveMessageConnectionResult.closed();
      }
      _channel = channel;
      // logger
      //   ..d('$logTag ===> TCP连接建立')
      //   ..d('$logTag ===> 发送认证包');
      _socketSubscription = channel.stream
          .map((data) => (data, Timeline.now))
          .asyncMap((event) => onData(event.$1, receivedAtUs: event.$2))
          .listen(
            (_) {},
            onDone: () => _fail(
              const LiveMessageConnectionResult.failed('直播消息连接已断开，请重试'),
            ),
            onError: (Object error, StackTrace stack) => _fail(
              LiveMessageConnectionResult.failed(
                '直播消息连接异常，请重试',
                cause: error,
                stackTrace: stack,
              ),
            ),
          );
      _channel?.sink.add(authPackage.marshal());
      final result = await _authentication.future.timeout(
        authenticationTimeout,
        onTimeout: () => LiveMessageConnectionResult.failed(
          '直播消息认证超时，请重试',
          cause: TimeoutException('等待直播消息认证超时', authenticationTimeout),
        ),
      );
      if (!_active) return _failure ?? const LiveMessageConnectionResult.closed();
      if (result.outcome == LiveMessageConnectionOutcome.failed) _fail(result);
      return result;
    } catch (error, stack) {
      if (!_active) {
        return _failure ?? const LiveMessageConnectionResult.closed();
      }
      final failure = LiveMessageConnectionResult.failed(
        '直播消息连接失败，请重试',
        cause: error,
        stackTrace: stack,
      );
      _fail(failure);
      return failure;
    }
  }

  void _fail(LiveMessageConnectionResult failure) {
    if (!_active) return;
    _failure = failure;
    logger.w(
      '${failure.message}${failure.code == null ? '' : '（代码：${failure.code}）'}',
      error: failure.cause?.runtimeType,
      stackTrace: failure.stackTrace,
    );
    close();
  }

  void _heartBeat() {
    if (!_active) {
      if (kDebugMode) logger.i("$logTag init heartBeat inactive $hashCode");
      close();
      return;
    }
    if (kDebugMode) logger.i("$logTag 直播间信息流认证成功 $hashCode");
    // 认证响应到达后才启动周期心跳，避免未认证连接发送业务心跳。
    int heartBeatCount = 1;
    _timer ??= Timer.periodic(heartbeatInterval, (timer) {
      if (!_active) {
        if (kDebugMode) logger.i("$logTag heartBeat inactive $hashCode");
        timer.cancel();
        close();
        return;
      }
      if (kDebugMode) logger.i("$logTag heartBeat $hashCode");
      final package = HeartbeatPackage(
        header: PackageHeader(
          protocolVer: 1,
          operationCode: 2,
          seq: heartBeatCount,
        ),
      );
      try {
        _channel?.sink.add(package.marshal());
      } catch (error, stack) {
        _fail(
          LiveMessageConnectionResult.failed(
            '直播消息心跳发送失败，请重试',
            cause: error,
            stackTrace: stack,
          ),
        );
      }
      heartBeatCount++;
    });
  }

  void addEventListener(void Function(dynamic) func) {
    _eventListeners.add(func);
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> onData(dynamic data, {int? receivedAtUs}) async {
    final received = receivedAtUs ?? Timeline.now;
    if (!_active || data is! List<int>) return;
    try {
      final packets = await _decoder.decode(
        data is Uint8List ? data : Uint8List.fromList(data),
      );
      if (!_active) return;
      // 拍下本批监听器快照，监听器增删不会改变正在分发的消息集合。
      final listeners = List.of(_eventListeners);
      for (final packet in packets) {
        if (!_active) break;
        if (packet.operationCode == 8) {
          final body = packet.body;
          final code = body is Map ? body['code'] : null;
          if (code != 0) {
            _fail(
              LiveMessageConnectionResult.failed(
                '直播消息认证失败，请刷新直播间重试',
                code: code is int ? code : null,
              ),
            );
            break;
          }
          if (!_authentication.isCompleted) {
            _authentication.complete(
              const LiveMessageConnectionResult.connected(),
            );
          }
          _heartBeat();
        }
        if (packet.body != null) {
          for (final listener in listeners) {
            if (!_active) break;
            try {
              final body = packet.body;
              listener(
                body is Map<String, dynamic>
                    ? LiveMessageBody(body, received)
                    : body,
              );
            } catch (_) {
              // 某个业务监听器失败不阻断剩余消息。
            }
          }
        }
      }
    } catch (error, stack) {
      if (_active) {
        _fail(
          LiveMessageConnectionResult.failed(
            '直播消息解析失败，请重试',
            cause: error,
            stackTrace: stack,
          ),
        );
      }
    }
  }

  void close() {
    if (!_active) return;
    // 先标记失活；随后到达的异步解析结果会因此被丢弃。
    _active = false;
    if (!_authentication.isCompleted) {
      _authentication.complete(
        _failure ?? const LiveMessageConnectionResult.closed(),
      );
    }
    _closed.complete();
    _connectingClient?.close(force: true);
    _decoder.close();
    if (kDebugMode) logger.i("$logTag close $hashCode");
    _timer?.cancel();
    _timer = null;
    _eventListeners.clear();
    final cancelling = _socketSubscription?.cancel();
    _socketSubscription = null;
    if (cancelling != null) _release(cancelling);
    final channel = _channel;
    _channel = null;
    if (channel != null) _release(channel.sink.close());
  }

  void _release(Future<dynamic> operation) {
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          logger.w('直播消息连接清理失败', error: error.runtimeType, stackTrace: stack);
        },
      ),
    );
  }
}

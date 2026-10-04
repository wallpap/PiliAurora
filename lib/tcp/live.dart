import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/tcp/live_packet.dart';
import 'package:pili_aurora/tcp/live_packet_decoder.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

export 'package:pili_aurora/tcp/live_packet.dart'
    show PackageHeader, PackageHeaderRes;

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
  });
  final Duration heartbeatInterval;
  final _decoder = LivePacketDecoder();

  bool _active = true;
  WebSocketChannel? _channel;
  StreamSubscription? _socketSubscription;
  Timer? _timer;
  static const String logTag = "LiveStreamService";

  Future<void> init() async {
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

    // final marshaledData = authPackage.marshal();
    // logger.d(marshaledData);
    try {
      Future<WebSocketChannel> getSocket() async {
        for (final server in servers) {
          try {
            final channel = WebSocketChannel.connect(Uri.parse(server));
            await channel.ready;
            return channel;
          } catch (error, stackTrace) {
            final uri = Uri.tryParse(server);
            final endpoint = uri == null || uri.host.isEmpty
                ? '<invalid endpoint>'
                : '${uri.host}:${uri.port == 0 ? 'default' : uri.port}';
            logger.w(
              '$logTag websocket connection failed: $endpoint',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
        throw Exception("all servers connect failed");
      }

      final channel = await getSocket();
      if (!_active) {
        if (kDebugMode) logger.i("$logTag init inactive $hashCode");
        await channel.sink.close();
        return;
      }
      _channel = channel;
      // logger
      //   ..d('$logTag ===> TCP连接建立')
      //   ..d('$logTag ===> 发送认证包');
      _socketSubscription = channel.stream
          .asyncMap(onData)
          .listen(
            (_) {},
            onDone: close,
            onError: (_) => close(),
          );
      _channel?.sink.add(authPackage.marshal());
    } catch (e) {
      if (_active) SmartDialog.showToast("弹幕地址链接失败: $e");
    }
  }

  void _heartBeat() {
    if (!_active) {
      if (kDebugMode) logger.i("$logTag init heartBeat inactive $hashCode");
      close();
      return;
    }
    if (kDebugMode) logger.i("$logTag 直播间信息流认证成功 $hashCode");
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
      } catch (_) {
        timer.cancel();
      }
      heartBeatCount++;
    });
  }

  void addEventListener(void Function(dynamic) func) {
    _eventListeners.add(func);
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> onData(dynamic data) async {
    if (!_active || data is! List<int>) return;
    try {
      final packets = await _decoder.decode(
        data is Uint8List ? data : Uint8List.fromList(data),
      );
      if (!_active) return;
      final listeners = List.of(_eventListeners);
      for (final packet in packets) {
        if (!_active) break;
        if (packet.operationCode == 8) _heartBeat();
        if (packet.body != null) {
          for (final listener in listeners) {
            if (!_active) break;
            try {
              listener(packet.body);
            } catch (_) {
              // 某个业务监听器失败不阻断剩余消息。
            }
          }
        }
      }
    } catch (_) {
      if (_active) {
        logger.w('直播消息解析失败');
        close();
      }
    }
  }

  void close() {
    if (!_active) return;
    _active = false;
    _decoder.close();
    if (kDebugMode) logger.i("$logTag close $hashCode");
    _timer?.cancel();
    _timer = null;
    _eventListeners.clear();
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _channel?.sink.close();
    _channel = null;
  }
}

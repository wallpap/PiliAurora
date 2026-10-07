import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart'
    show MethodChannel, EventChannel, DeviceOrientation;
import 'package:native_device_orientation/src/native_device_orientation_platform_interface.dart';

DeviceOrientation _fromString(String orientationString) =>
    DeviceOrientation.values.byName(orientationString);

class _OrientationStream {
  final Stream<OrientationParams> stream;
  final int? angleDegrees;
  final bool checkIsAutoRotate;

  _OrientationStream({
    required this.stream,
    this.angleDegrees,
    required this.checkIsAutoRotate,
  });
}

/// An implementation of [NativeDeviceOrientationPlatform] that uses method channels.
class MethodChannelNativeDeviceOrientation
    extends NativeDeviceOrientationPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('native_device_orientation');
  @visibleForTesting
  final eventChannel = const EventChannel('native_device_orientation_events');

  _OrientationStream? _stream;

  @override
  Future<void> pause() {
    return methodChannel.invokeMethod('pause');
  }

  @override
  Future<void> resume() {
    return methodChannel.invokeMethod('resume');
  }

  @override
  Stream<OrientationParams> onOrientationChanged({
    int? angleDegrees,
    bool checkIsAutoRotate = true,
  }) {
    if (_stream == null ||
        _stream!.angleDegrees != angleDegrees ||
        _stream!.checkIsAutoRotate != checkIsAutoRotate) {
      final params = <String, dynamic>{
        'angleDegrees': angleDegrees,
        'checkIsAutoRotate': checkIsAutoRotate,
      };
      _stream = _OrientationStream(
        stream:
            eventChannel.receiveBroadcastStream(params).map((dynamic event) {
          if (event is Map) {
            return (
              orientation: _fromString(event['orientation']),
              isAutoRotate: event['isAutoRotate'],
            );
          }
          return (
            orientation: _fromString(event),
            isAutoRotate: null,
          );
        }),
        angleDegrees: angleDegrees,
        checkIsAutoRotate: checkIsAutoRotate,
      );
    }
    return _stream!.stream;
  }
}

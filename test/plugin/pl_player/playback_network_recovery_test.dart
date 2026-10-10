import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/playback_network_recovery.dart';

void main() {
  group('分离音视频断流日志', () {
    test('终止传输和截断媒体需要恢复', () {
      for (final (prefix, message) in [
        ('curl', 'transfer failed: Failure when receiving data from the peer'),
        ('curl', 'transfer failed: Failed sending data to the peer'),
        (
          'ffmpeg',
          'https: Stream ends prematurely at 6077440, should be 12527587',
        ),
        (
          'ffmpeg',
          'http: Stream ends prematurely at 6077440, should be 12527587',
        ),
        (
          'ffmpeg/demuxer',
          'mov,mp4,m4a,3gp,3g2,mj2: stream 0, offset 0x67358bd: partial file',
        ),
      ]) {
        for (final level in ['error', 'fatal']) {
          expect(
            isPlaybackStreamReadFailure(
              prefix: prefix,
              level: level,
              message: message,
            ),
            isTrue,
            reason: '$prefix $level: $message',
          );
        }
      }
    });

    test('原生重试、权限错误和解码错误保持各自处理路径', () {
      for (final (prefix, level, message) in [
        (
          'curl',
          'warn',
          'Failure when receiving data from the peer, retrying (#1) from 96018379',
        ),
        ('curl', 'error', 'HTTP error 403 Forbidden'),
        ('ffmpeg', 'error', 'HTTP error 403 Forbidden'),
        (
          'ffmpeg',
          'warn',
          'https: Stream ends prematurely at 6077440, should be 12527587',
        ),
        ('ffmpeg', 'error', 'tls: mbedtls_ssl_handshake returned -0x7280'),
        ('libmpv_render/dxva2-egl', 'error', 'Failed to create EGL surface'),
        ('ffmpeg/video', 'error', 'av1: Invalid OBU length: 75509'),
        ('ffmpeg/demuxer', 'warn', 'Packet corrupt (stream = 0).'),
      ]) {
        expect(
          isPlaybackStreamReadFailure(
            prefix: prefix,
            level: level,
            message: message,
          ),
          isFalse,
          reason: '$prefix $level: $message',
        );
      }
    });
  });

  group('2026-10-07 Android network failures', () {
    for (final event in [
      'tls: mbedtls_ssl_handshake returned -0x7280',
      'tls: mbedtls_ssl_read returned -0x0',
      'tls: mbedtls_ssl_read reported connection reset by peer',
      'https: Error reading HTTP response: I/O error',
      'https: Stream ends prematurely at 6077440, should be 12527587',
      'tcp: ffurl_read returned 0xffffff99',
    ]) {
      test('retries $event', () {
        expect(isPlaybackNetworkFailure(event), isTrue);
      });
    }

    test('stalled playback with nonzero absolute buffer can reconnect', () {
      expect(
        hasExhaustedPlaybackBuffer(
          buffering: true,
          position: const Duration(seconds: 90),
          buffer: const Duration(seconds: 90),
        ),
        isTrue,
      );
    });

    test('remaining buffered media is not interrupted', () {
      expect(
        hasExhaustedPlaybackBuffer(
          buffering: true,
          position: const Duration(seconds: 90),
          buffer: const Duration(seconds: 94),
        ),
        isFalse,
      );
      expect(
        shouldDeferPlaybackNetworkRecovery(
          buffering: true,
          position: const Duration(seconds: 90),
          buffer: const Duration(seconds: 94),
        ),
        isTrue,
      );
    });

    test('healthy playback and codec failures do not reconnect', () {
      expect(
        hasExhaustedPlaybackBuffer(
          buffering: false,
          position: const Duration(seconds: 90),
          buffer: Duration.zero,
        ),
        isFalse,
      );
      expect(
        shouldDeferPlaybackNetworkRecovery(
          buffering: false,
          position: const Duration(seconds: 90),
          buffer: Duration.zero,
        ),
        isFalse,
      );
      for (final event in [
        'libdav1d: Error parsing OBU data',
        'av1_mediacodec: Both surface and native_window are NULL',
        'Error while decoding frame!',
        'http: HTTP error 403 Forbidden',
        'Failed to open https://cdn.example/video: HTTP error 403 Forbidden',
      ]) {
        expect(isPlaybackNetworkFailure(event), isFalse);
      }
    });

    test('missing or temporarily unavailable CDN nodes can fail over', () {
      for (final event in [
        'http: HTTP error 404 Not Found',
        'http: HTTP error 408 Request Timeout',
        'http: HTTP error 429 Too Many Requests',
        'http: HTTP error 503 Service Unavailable',
      ]) {
        expect(isPlaybackNetworkFailure(event), isTrue, reason: event);
      }
    });

    test('in-range seek errors can trigger network recovery', () {
      expect(
        isPlaybackNetworkFailure(
          'Seek failed (to 40493344, size 169462757)',
        ),
        isTrue,
      );
    });

    test('invalid and unauthorized seeks do not trigger network recovery', () {
      for (final event in [
        'Seek failed (to 169462757, size 169462757)',
        'Seek failed (to 200000000, size 169462757)',
        'Seek failed (to invalid, size 169462757)',
        'http: HTTP error 403 Forbidden\nSeek failed (to 40493344, size 169462757)',
      ]) {
        expect(isPlaybackNetworkFailure(event), isFalse, reason: event);
      }
    });
  });
}

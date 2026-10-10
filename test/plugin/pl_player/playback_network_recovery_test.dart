import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/playback_network_recovery.dart';

void main() {
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

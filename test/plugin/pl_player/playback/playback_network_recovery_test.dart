import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/playback_network_recovery.dart';

void main() {
  test('诊断回放：CDN 主机名解析失败属于可限次恢复的网络错误', () {
    expect(
      isPlaybackNetworkFailure(
        'tcp: Failed to resolve hostname cdn.example.test: '
        'No address associated with hostname',
      ),
      isTrue,
    );
  });

  test('DNS 组合日志分类保留权限优先并排除解码错误', () {
    for (final message in [
      'tcp: Failed to resolve hostname cdn.example.test: Temporary failure in name resolution',
      'Packet corrupt\ntcp: Failed to resolve hostname cdn.example.test: No address associated with hostname',
      'tcp: Failed to resolve hostname cdn.example.test: Name or service not known',
    ]) {
      expect(isPlaybackNetworkFailure(message), isTrue, reason: message);
    }
    for (final message in [
      'tcp: Failed to resolve hostname cdn.example.test: No address associated with hostname\nhttp: HTTP error 403 Forbidden',
      'http: HTTP error 503 Service Unavailable\nhttp: HTTP error 403 Forbidden',
      'av1: Failed to resolve hostname metadata',
      'tcp: Failed to resolve hostname cdn.example.test: Invalid argument',
    ]) {
      expect(isPlaybackNetworkFailure(message), isFalse, reason: message);
    }
  });

  test('网络故障可恢复，权限、解码与无效 seek 保留各自处理路径', () {
    for (final (expected, events) in [
      (
        true,
        [
          'tls: TLS handshake failed.',
          'tls: mbedtls_ssl_handshake returned -0x7280',
          'https: Stream ends prematurely at 6077440, should be 12527587',
          'http: HTTP error 404 Not Found',
          'http: HTTP error 408 Request Timeout',
          'http: HTTP error 429 Too Many Requests',
          'http: HTTP error 503 Service Unavailable',
          'Seek failed (to 40493344, size 169462757)',
        ],
      ),
      (
        false,
        [
          'tls: TLS handshake failed.\nhttp: HTTP error 403 Forbidden',
          'libdav1d: Error parsing OBU data',
          'av1_mediacodec: Both surface and native_window are NULL',
          'Error while decoding frame!',
          'http: HTTP error 403 Forbidden',
          'Failed to open https://cdn.example/video: HTTP error 403 Forbidden',
          'Seek failed (to 169462757, size 169462757)',
          'Seek failed (to 200000000, size 169462757)',
          'Seek failed (to invalid, size 169462757)',
          'http: HTTP error 403 Forbidden\nSeek failed (to 40493344, size 169462757)',
        ],
      ),
    ]) {
      for (final event in events) {
        expect(isPlaybackNetworkFailure(event), expected, reason: event);
      }
    }
  });

  test('缓冲使用绝对时间戳，仍有内容时延后恢复，健康播放不重连', () {
    for (final (buffering, buffer, exhausted, defer) in [
      (true, 90, true, false),
      (true, 94, false, true),
      (false, 0, false, false),
    ]) {
      expect(
        hasExhaustedPlaybackBuffer(
          buffering: buffering,
          position: const Duration(seconds: 90),
          buffer: Duration(seconds: buffer),
        ),
        exhausted,
      );
      expect(
        shouldDeferPlaybackNetworkRecovery(
          buffering: buffering,
          position: const Duration(seconds: 90),
          buffer: Duration(seconds: buffer),
        ),
        defer,
      );
    }
  });

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
}

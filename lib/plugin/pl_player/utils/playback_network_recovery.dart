/// 只把原生播放器明确报告的连接/读取中断交给重连，排除解码和 HTTP 状态错误。
bool isPlaybackNetworkFailure(String event) =>
    event.startsWith('Failed to open https://') ||
    event.startsWith('Can not open external file https://') ||
    event.startsWith('tcp: ffurl_read returned ') ||
    event.startsWith('tls: mbedtls_ssl_handshake returned ') ||
    event.startsWith('tls: mbedtls_ssl_read returned ') ||
    event.startsWith(
      'tls: mbedtls_ssl_read reported connection reset by peer',
    ) ||
    event.startsWith('https: Error reading HTTP response:') ||
    event.startsWith('https: Stream ends prematurely at ');

/// mpv 的 buffer 是最后一个已缓冲时间戳，非剩余缓冲时长。
bool hasExhaustedPlaybackBuffer({
  required bool buffering,
  required Duration position,
  required Duration buffer,
}) => buffering && buffer <= position;

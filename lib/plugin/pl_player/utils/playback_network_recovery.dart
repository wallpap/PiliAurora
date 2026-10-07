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

/// 网络错误后仍在缓冲且还有可播放内容时，暂缓重连但不要丢弃重试机会。
///
/// mpv 的 [buffer] 是绝对时间戳。控制器需要在这个状态下重新安排检查，
/// 否则一次定时检查恰好早于缓冲耗尽时，后续没有新的错误事件就不会重连。
bool shouldDeferPlaybackNetworkRecovery({
  required bool buffering,
  required Duration position,
  required Duration buffer,
}) => buffering && buffer > position;

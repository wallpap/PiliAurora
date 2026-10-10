/// 只把连接中断和 CDN 临时失效交给重试，HTTP 403 仍按权限错误处理。
bool isPlaybackNetworkFailure(String event) {
  final status = RegExp(r'HTTP error (\d{3})\b').firstMatch(event)?.group(1);
  if (status != null) {
    final code = int.parse(status);
    return code == 404 ||
        code == 408 ||
        code == 429 ||
        (code >= 500 && code < 600);
  }

  final failedSeek = RegExp(
    r'^Seek failed \(to (\d+), size (\d+)\)$',
  ).firstMatch(event);
  if (failedSeek != null) {
    // 文件内 seek 失败可能来自下载不完整；越过文件末尾则是无效位置。
    return int.parse(failedSeek.group(1)!) < int.parse(failedSeek.group(2)!);
  }

  if (event.startsWith('Failed to open https://') ||
      event.startsWith('Can not open external file https://') ||
      event.startsWith('tcp: ffurl_read returned ') ||
      event.startsWith('tls: mbedtls_ssl_handshake returned ') ||
      event.startsWith('tls: mbedtls_ssl_read returned ') ||
      event.startsWith(
        'tls: mbedtls_ssl_read reported connection reset by peer',
      ) ||
      event.startsWith('https: Error reading HTTP response:') ||
      event.startsWith('https: Stream ends prematurely at ')) {
    return true;
  }

  return false;
}

/// 读取已终止时，独立音轨仍可能推进播放时钟，整体 buffering 不会置位。
bool isPlaybackStreamReadFailure({
  required String prefix,
  required String level,
  required String message,
}) {
  if (level != 'error' && level != 'fatal') return false;
  if (prefix == 'curl') {
    return message.startsWith('transfer failed:') &&
        (message.contains('Failure when receiving data from the peer') ||
            message.contains('Failed sending data to the peer'));
  }
  if (prefix == 'ffmpeg') {
    return message.startsWith('https: Stream ends prematurely at ') ||
        message.startsWith('http: Stream ends prematurely at ');
  }
  return prefix == 'ffmpeg/demuxer' && message.endsWith(': partial file');
}

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

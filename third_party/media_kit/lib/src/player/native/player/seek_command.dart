/// 构造原生跳转命令。Android 同文件播放优先关键帧，减少 MediaCodec 解码负担。
/// 独立音轨按请求时间定位；视频也须精确定位，否则视频提前播放时会等待音轨。
List<String> nativeSeekCommand(
  Duration position, {
  bool keyframe = false,
  bool externalAudio = false,
  Map<String, dynamic>? mediaExtras,
}) {
  final separateAudio =
      externalAudio ||
      (mediaExtras?.containsKey('audio-files-append') ?? false) ||
      (mediaExtras?.containsKey('audio-files') ?? false);
  final flags = keyframe
      ? separateAudio
            ? 'absolute+exact'
            : 'absolute+keyframes'
      : 'absolute';
  return ['seek', (position.inMilliseconds / 1000).toStringAsFixed(3), flags];
}

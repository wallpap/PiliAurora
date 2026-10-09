/// Builds the libmpv seek command used by the native player.
///
/// Android progress seeks use keyframe boundaries. Exact seeks make the decoder
/// drain from the previous keyframe to the requested timestamp, which is
/// disproportionately expensive for MediaCodec and can turn a normal progress
/// jump into a decode/output failure.
List<String> nativeSeekCommand(Duration position, {bool keyframe = false}) => [
      'seek',
      (position.inMilliseconds / 1000).toStringAsFixed(3),
      keyframe ? 'absolute+keyframes' : 'absolute',
    ];

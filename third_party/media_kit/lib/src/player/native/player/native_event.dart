import 'native_hook.dart';

/// Copied lifecycle facts emitted by the native player event reader.
///
/// These values never retain an mpv event pointer. A missing playlist entry ID
/// means the linked mpv client API is too old to provide a causal identity.
sealed class NativePlayerEvent {
  const NativePlayerEvent();
}

final class NativeStartFile extends NativePlayerEvent {
  const NativeStartFile({required this.playlistEntryId});

  final int? playlistEntryId;
}

final class NativeFileLoaded extends NativePlayerEvent {
  NativeFileLoaded({
    required this.playlistEntryId,
    this.videoOutputParameters,
    List<NativeVideoTrackMetadata>? videoTracks,
    this.hasAudio,
    this.seekable,
    this.partiallySeekable,
  }) : videoTracks = videoTracks == null
           ? null
           : List<NativeVideoTrackMetadata>.unmodifiable(videoTracks);

  /// The identity copied from the latest start-file event, if known.
  final int? playlistEntryId;

  /// Output geometry copied while handling this FILE_LOADED event.
  ///
  /// A missing value means that the event had no proven file identity or that
  /// libmpv could not provide a complete `video-out-params` snapshot.
  final NativeVideoOutputParameters? videoOutputParameters;

  /// Complete copied video-track snapshot from this FILE_LOADED event.
  /// `null` means the property was unreadable; an empty list confirms no video.
  final List<NativeVideoTrackMetadata>? videoTracks;

  /// Whether a selected audio track was present in this same track snapshot.
  /// Unknown selection data remains null.
  final bool? hasAudio;

  /// Same-reader FILE_LOADED samples. Null means mpv did not provide a flag.
  final bool? seekable;
  final bool? partiallySeekable;
}

/// Later output-geometry snapshot copied from a `video-out-params` property
/// event and tagged with the playlist entry active when the reader received it.
final class NativeVideoOutputParametersChanged extends NativePlayerEvent {
  const NativeVideoOutputParametersChanged({
    required this.playlistEntryId,
    required this.videoOutputParameters,
  });

  final int? playlistEntryId;
  final NativeVideoOutputParameters? videoOutputParameters;
}

/// Updated track selection copied from a `track-list` property event.
final class NativeTracksChanged extends NativePlayerEvent {
  NativeTracksChanged({
    required this.playlistEntryId,
    List<NativeVideoTrackMetadata>? videoTracks,
    this.hasAudio,
  }) : videoTracks = videoTracks == null
           ? null
           : List<NativeVideoTrackMetadata>.unmodifiable(videoTracks);

  final int? playlistEntryId;
  final List<NativeVideoTrackMetadata>? videoTracks;
  final bool? hasAudio;
}

enum NativeEndFileReason { eof, stop, quit, error, redirect, unknown }

/// keep-open 模式下的播放结束事实；文件尚未卸载，仍可 seek 后继续播放。
final class NativePlaybackEof extends NativePlayerEvent {
  const NativePlaybackEof({
    required this.playlistEntryId,
    required this.reached,
    required this.position,
    required this.duration,
  });

  final int? playlistEntryId;
  final bool reached;
  final Duration position;
  final Duration duration;
}

final class NativeEndFile extends NativePlayerEvent {
  const NativeEndFile({
    required this.playlistEntryId,
    required this.reason,
    required this.error,
  });

  final int? playlistEntryId;
  final NativeEndFileReason reason;
  final int error;
}

final class NativeEventQueueOverflow extends NativePlayerEvent {
  const NativeEventQueueOverflow();
}

/// Confirms that the single native reader drained the event queue to NONE.
final class NativeEventBatchDrained extends NativePlayerEvent {
  const NativeEventBatchDrained({required this.batchId});

  final int batchId;
}

/// 由同一 reader 的命令回执、SEEK、PLAYBACK_RESTART 顺序确认。
final class NativeSeekCompleted extends NativePlayerEvent {
  const NativeSeekCompleted({
    required this.playlistEntryId,
    required this.observationId,
  });

  final int playlistEntryId;
  final int observationId;
}

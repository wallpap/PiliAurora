import 'dart:io' show File, Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/grpc/bilibili/app/listener/v1.pb.dart'
    show DetailItem;
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/models/remote/live/live_room_info_h5/data.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/episode.dart';
import 'package:pili_aurora/models/remote/video/video_detail/data.dart';
import 'package:pili_aurora/models/remote/video/video_detail/page.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/utils/android/bindings.g.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as path;

Future<VideoPlayerServiceHandler> initAudioService() {
  return AudioService.init(
    builder: VideoPlayerServiceHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'io.github.wallpap.piliaurora.audio',
      androidNotificationChannelName: 'Audio Service ${Constants.appName}',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
      androidNotificationChannelDescription: 'Media notification channel',
      androidNotificationIcon: 'drawable/ic_notification_icon',
      artDownscaleWidth: 512,
      artDownscaleHeight: 512,
    ),
  );
}

typedef _StatusConfig = (
  PlayerStatus status,
  bool isBuffering,
  bool isLive,
  double speed,
  bool loading,
);

class VideoPlayerServiceHandler extends BaseAudioHandler with SeekHandler {
  final List<MediaItem> _item = [];
  bool _enableBackgroundPlay = Pref.enableBackgroundPlay;
  PlaybackKeepAliveLease? _playbackLease;

  bool get enableBackgroundPlay => _enableBackgroundPlay;
  set enableBackgroundPlay(bool value) {
    if (_enableBackgroundPlay == value) return;
    _enableBackgroundPlay = value;
    if (!value) {
      _clearPublishedState();
    } else if (_item.isNotEmpty) {
      setMediaItem(_item.last);
      final config = _currentConfig;
      if (config != null) {
        onUpdateState(
          config.$1,
          config.$2,
          config.$3,
          position: _currentPosition,
          speed: config.$4,
          loading: config.$5,
        );
      }
    }
  }

  void _retainPlaybackLease() {
    if (_playbackLease != null || !enableBackgroundPlay) return;
    final controller = PlPlayerController.instance;
    final owner = controller?.activePlaybackOwner;
    if (controller != null && owner != null) {
      _playbackLease = controller.acquirePlaybackKeepAlive(owner);
    }
  }

  void _releasePlaybackLease() {
    _playbackLease?.close();
    _playbackLease = null;
  }

  Future<void>? Function()? onPlay;
  Future<void>? Function()? onPause;
  Future<void>? Function(Duration position)? onSeek;

  @override
  Future<void> play() async {
    final callback = onPlay;
    if (callback != null) {
      await callback();
    } else {
      await PlPlayerController.playIfExists();
    }
  }

  @override
  Future<void> pause() async {
    final callback = onPause;
    if (callback != null) {
      await callback();
    } else {
      await PlPlayerController.pauseIfExists();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    final callback = onSeek;
    if (callback != null) {
      await callback(position);
    } else {
      await PlPlayerController.seekToIfExists(position, isSeek: false);
    }
  }

  void setMediaItem(MediaItem newMediaItem) {
    if (!enableBackgroundPlay) return;
    _retainPlaybackLease();
    if (!mediaItem.isClosed) mediaItem.add(newMediaItem);
  }

  Duration? _lastPos;
  _StatusConfig? _lastConfig;
  _StatusConfig? _currentConfig;
  Duration _currentPosition = Duration.zero;
  void onUpdateState(
    PlayerStatus status,
    bool isBuffering,
    bool isLive, {
    required Duration position,
    required double speed,
    bool loading = false,
    String? debugLabel,
  }) {
    if (onPlay != null && debugLabel == 'onVideoPaused') return;
    final newConfig = (status, isBuffering, isLive, speed, loading);
    _currentConfig = newConfig;
    _currentPosition = position;
    if (!enableBackgroundPlay || _item.isEmpty) return;
    if (_lastConfig == newConfig) {
      if (_lastPos != null) {
        final pos = position.inSeconds;
        final lastPos = _lastPos!.inSeconds;
        _lastPos = position;
        if (pos == lastPos && pos != 0) return;
      }
    }
    _lastConfig = newConfig;

    final AudioProcessingState processingState;
    final bool playing;
    if (loading) {
      playing = false;
      processingState = .loading;
    } else {
      switch (status) {
        case .completed:
          playing = false;
          processingState = .completed;
        case .playing:
          playing = true;
          processingState = isBuffering ? .buffering : .ready;
        case .paused:
          playing = false;
          processingState = isBuffering ? .buffering : .ready;
      }
    }
    _updateState(
      processingState,
      playing,
      isLive,
      position: position,
      speed: speed,
    );
  }

  void _updateState(
    AudioProcessingState state,
    bool playing,
    bool isLive, {
    required Duration position,
    required double speed,
  }) {
    playbackState.add(
      playbackState.value.copyWith(
        processingState: state,
        updatePosition: position,
        speed: speed,
        controls: [
          if (!isLive)
            const MediaControl(
              androidIcon: 'drawable/ic_player_rewind_10s',
              label: 'Rewind',
              action: .rewind,
            ),
          if (playing)
            const MediaControl(
              androidIcon: 'drawable/ic_player_pause',
              label: 'Pause',
              action: .pause,
            )
          else
            const MediaControl(
              androidIcon: 'drawable/ic_player_play',
              label: 'Play',
              action: .play,
            ),
          if (!isLive)
            const MediaControl(
              androidIcon: 'drawable/ic_player_fast_forward_10s',
              label: 'Fast Forward',
              action: .fastForward,
            ),
        ],
        playing: playing,
        systemActions: const {.seek},
      ),
    );
    if (Platform.isAndroid &&
        (AndroidHelper.isPipMode ||
            PlPlayerController.instance?.isAutoEnterPip == true)) {
      AndroidHelper.updatePipActions(
        PlatformDispatcher.instance.engineId!,
        isLive,
        playing,
      );
    }
  }

  void onVideoDetailChange(
    dynamic data,
    int cid,
    String herotag, {
    String? artist,
    String? cover,
  }) {
    if (data == null) return;

    Uri getUri(String? cover) => Uri.parse(ImageUtils.safeThumbnailUrl(cover));

    late final id = '$cid$herotag';
    final MediaItem mediaItem;
    switch (data) {
      case VideoDetailData(:final pages):
        if (pages != null && pages.length > 1) {
          final current = pages.firstWhereOrNull((e) => e.cid == cid);
          mediaItem = MediaItem(
            id: id,
            title: current?.part ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: current?.duration ?? 0),
            artUri: getUri(data.pic),
          );
        } else {
          mediaItem = MediaItem(
            id: id,
            title: data.title ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: data.duration ?? 0),
            artUri: getUri(data.pic),
          );
        }
      case EpisodeItem():
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle ?? data.longTitle ?? data.title ?? '',
          artist: artist,
          duration: data.from == 'pugv'
              ? Duration(seconds: data.duration ?? 0)
              : Duration(milliseconds: data.duration ?? 0),
          artUri: getUri(data.cover),
        );
      case RoomInfoH5Data():
        mediaItem = MediaItem(
          id: id,
          title: data.roomInfo?.title ?? '',
          artist: data.anchorInfo?.baseInfo?.uname,
          artUri: getUri(data.roomInfo?.cover),
          isLive: true,
        );
      case Part():
        mediaItem = MediaItem(
          id: id,
          title: data.part ?? '',
          artist: artist,
          duration: Duration(seconds: data.duration ?? 0),
          artUri: getUri(cover),
        );
      case DetailItem(:final arc):
        mediaItem = MediaItem(
          id: id,
          title: arc.title,
          artist: data.owner.name,
          duration: Duration(seconds: arc.duration.toInt()),
          artUri: getUri(arc.cover),
        );
      case BiliDownloadEntryInfo():
        final coverFile = File(
          path.join(data.entryDirPath, PathUtils.coverName),
        );
        final uri = coverFile.existsSync()
            ? coverFile.absolute.uri
            : getUri(data.cover);
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle,
          artist: data.ownerName,
          duration: Duration(milliseconds: data.totalTimeMilli),
          artUri: uri,
        );
      default:
        return;
    }
    _item.removeWhere((item) => item.id.endsWith(herotag));
    _item.add(mediaItem);
    setMediaItem(mediaItem);
  }

  void onVideoDetailDispose(String herotag) {
    final wasCurrent = _item.lastOrNull?.id.endsWith(herotag) == true;
    if (_item.isNotEmpty) {
      _item.removeWhere((item) => item.id.endsWith(herotag));
    }
    if (_item.isEmpty) {
      clear();
      return;
    }
    if (!wasCurrent) return;
    _currentConfig = null;
    _lastConfig = null;
    _lastPos = null;
    if (!enableBackgroundPlay) return;
    setMediaItem(_item.last);
    playbackState.add(
      playbackState.value.copyWith(processingState: .ready, playing: false),
    );
  }

  void clearIfNeeded() {
    if (!enableBackgroundPlay) {
      _clearPublishedState();
      return;
    }
    if (_item.isEmpty) clear();
  }

  void clear() {
    _item.clear();
    _currentConfig = null;
    _currentPosition = Duration.zero;
    _clearPublishedState();
  }

  void _clearPublishedState() {
    if (!mediaItem.isClosed) mediaItem.add(null);
    _lastPos = null;
    _lastConfig = null;
    /**
     * if (playbackState.processingState == AudioProcessingState.idle &&
            previousState?.processingState != AudioProcessingState.idle) {
          await AudioService._stop();
        }
     */
    if (playbackState.value.processingState == .idle) {
      playbackState.add(PlaybackState(processingState: .completed));
    }
    playbackState.add(PlaybackState(processingState: .idle));
    _releasePlaybackLease();
  }

  @override
  Future<void> stop() async {
    final current = _item.lastOrNull;
    await pause();
    // 暂停回执只能结束发起时的媒体，不能清除等待期间换入的通知。
    if (identical(_item.lastOrNull, current)) clear();
  }
}

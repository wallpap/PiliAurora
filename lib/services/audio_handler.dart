import 'dart:async' show FutureOr, Timer;
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
import 'package:pili_aurora/services/logger.dart';
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

/// 与一条系统媒体信息共同存活的业务导航，不从全局路由反查控制器。
class MediaNavigation {
  const MediaNavigation({required this.isCurrent, this.next, this.previous});

  final bool Function() isCurrent;
  final FutureOr<bool> Function()? next;
  final FutureOr<bool> Function()? previous;
}

typedef _ServiceMedia = ({
  String owner,
  MediaItem item,
  MediaNavigation? navigation,
});

class VideoPlayerServiceHandler extends BaseAudioHandler {
  final List<_ServiceMedia> _item = [];
  bool _enableBackgroundPlay = Pref.enableBackgroundPlay;
  PlaybackKeepAliveLease? _playbackLease;

  bool get enableBackgroundPlay => _enableBackgroundPlay;
  set enableBackgroundPlay(bool value) {
    if (_enableBackgroundPlay == value) return;
    _enableBackgroundPlay = value;
    if (!value) {
      _clearPublishedState();
    } else if (_item.isNotEmpty) {
      setMediaItem(_item.last.item);
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
  Future<void>? Function(Duration position)? _onSeek;
  Future<void>? Function(Duration position)? get onSeek => _onSeek;
  set onSeek(Future<void>? Function(Duration position)? callback) {
    if (_onSeek == callback) return;
    _stopContinuousSeek();
    _resetSeekTarget();
    _onSeek = callback;
  }

  Duration? _seekTarget;
  String? _seekMediaId;
  Object? _seekOwner;
  int _seekRevision = 0;

  void _resetSeekTarget() {
    _seekRevision++;
    _seekTarget = null;
    _seekMediaId = null;
    _seekOwner = null;
  }

  @override
  Future<void> fastForward() =>
      _seekRelative(AudioService.config.fastForwardInterval);

  @override
  Future<void> rewind() => _seekRelative(-AudioService.config.rewindInterval);

  Timer? _relativeSeekTimer;

  void _stopContinuousSeek() {
    _relativeSeekTimer?.cancel();
    _relativeSeekTimer = null;
  }

  @override
  Future<void> seekForward(bool begin) => _seekContinuously(begin, 1);

  @override
  Future<void> seekBackward(bool begin) => _seekContinuously(begin, -1);

  Future<void> _seekContinuously(bool begin, int direction) async {
    _stopContinuousSeek();
    final item = mediaItem.value;
    if (!begin || item == null || item.isLive == true || item.duration == null)
      return;
    final callback = onSeek;
    final owner = PlPlayerController.instance?.activePlaybackOwner;
    final offset = Duration(seconds: 10 * direction);
    final timer = _relativeSeekTimer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) {
        if (mediaItem.value?.id != item.id ||
            onSeek != callback ||
            !identical(
              owner,
              PlPlayerController.instance?.activePlaybackOwner,
            )) {
          if (identical(_relativeSeekTimer, timer)) _stopContinuousSeek();
          return;
        }
        _seekRelative(offset).catchError((Object error, StackTrace stack) {
          if (identical(_relativeSeekTimer, timer)) _stopContinuousSeek();
          logger.w('系统连续跳转失败', error: error.runtimeType, stackTrace: stack);
        });
      },
    );
    try {
      await _seekRelative(offset);
    } catch (_) {
      if (identical(_relativeSeekTimer, timer)) _stopContinuousSeek();
      rethrow;
    }
  }

  Future<void> _seekRelative(Duration offset) async {
    final item = mediaItem.value;
    if (item == null || item.isLive == true) return;
    final targetCurrent =
        _seekMediaId == item.id &&
        identical(_seekOwner, PlPlayerController.instance?.activePlaybackOwner);
    final base = targetCurrent ? _seekTarget : null;
    var target = (base ?? playbackState.value.position) + offset;
    if (target < Duration.zero) target = Duration.zero;
    final duration = item.duration;
    if (duration != null && target > duration) target = duration;
    await seek(target);
  }

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
    final revision = ++_seekRevision;
    // 命令回执可能早于位置事件，保留最新意图供连续相对跳转累计。
    _seekTarget = position;
    _seekMediaId = mediaItem.value?.id;
    _seekOwner = PlPlayerController.instance?.activePlaybackOwner;
    final callback = onSeek;
    try {
      if (callback != null) {
        await callback(position);
      } else {
        await PlPlayerController.seekToIfExists(position, isSeek: false);
      }
    } catch (_) {
      if (_seekRevision == revision) _resetSeekTarget();
      rethrow;
    }
  }

  void setMediaItem(MediaItem newMediaItem) {
    if (!enableBackgroundPlay) return;
    if (mediaItem.value?.id != newMediaItem.id) {
      _stopContinuousSeek();
      _resetSeekTarget();
    }
    _retainPlaybackLease();
    if (!mediaItem.isClosed) mediaItem.add(newMediaItem);
    playbackState.add(
      playbackState.value.copyWith(systemActions: _mediaActions),
    );
  }

  MediaNavigation? get _currentNavigation {
    final entry = _item.lastOrNull;
    if (!enableBackgroundPlay ||
        entry == null ||
        entry.item.isLive == true ||
        entry.item.id != mediaItem.value?.id)
      return null;
    final navigation = entry.navigation;
    return navigation?.isCurrent() == true ? navigation : null;
  }

  Set<MediaAction> get _mediaActions {
    final navigation = _currentNavigation;
    return {
      if (mediaItem.value?.isLive != true) MediaAction.seek,
      if (navigation?.next != null) MediaAction.skipToNext,
      if (navigation?.previous != null) MediaAction.skipToPrevious,
    };
  }

  @override
  Future<void> skipToNext() async {
    _stopContinuousSeek();
    await _currentNavigation?.next?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    _stopContinuousSeek();
    await _currentNavigation?.previous?.call();
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
    if (_seekTarget case final target? when !isBuffering && !loading) {
      if ((position - target).abs() <= const Duration(seconds: 1)) {
        _resetSeekTarget();
      }
    }
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
        systemActions: _mediaActions,
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
    MediaNavigation? navigation,
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
    _item.removeWhere((entry) => entry.owner == herotag);
    _item.add((owner: herotag, item: mediaItem, navigation: navigation));
    setMediaItem(mediaItem);
  }

  void onVideoDetailDispose(String herotag) {
    final wasCurrent = _item.lastOrNull?.owner == herotag;
    if (_item.isNotEmpty) {
      _item.removeWhere((entry) => entry.owner == herotag);
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
    setMediaItem(_item.last.item);
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
    _stopContinuousSeek();
    _resetSeekTarget();
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
    final current = _item.lastOrNull?.item;
    await pause();
    // 暂停回执只能结束发起时的媒体，不能清除等待期间换入的通知。
    if (identical(_item.lastOrNull?.item, current)) clear();
  }
}

import 'package:pili_aurora/plugin/pl_player/playback/frame_timing.dart';

import 'dart:async' show Completer, StreamSubscription, Timer, unawaited;
import 'dart:convert' show ascii;
import 'dart:io' show Platform;
import 'dart:math' show max, min;

import 'package:pili_aurora/utils/volume_utils.dart';
import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/audio_normalization.dart';
import 'package:pili_aurora/models/common/super_resolution_type.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/user/danmaku_rule.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/models/remote/video/video_shot/data.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/display_binding.dart';
import 'package:pili_aurora/pages/danmaku/interaction.dart';
import 'package:pili_aurora/pages/sponsor_block/block_mixin.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_status.dart';
import 'package:pili_aurora/plugin/pl_player/models/double_tap_type.dart';
import 'package:pili_aurora/plugin/pl_player/models/duration.dart';
import 'package:pili_aurora/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:pili_aurora/plugin/pl_player/models/heart_beat_type.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_repeat.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:pili_aurora/plugin/pl_player/models/video_fit_type.dart';
import 'package:pili_aurora/plugin/pl_player/utils/fullscreen.dart';
import 'package:pili_aurora/plugin/pl_player/utils/decode_fallback.dart';
import 'package:pili_aurora/plugin/pl_player/utils/android_decode_recovery.dart';
import 'package:pili_aurora/plugin/pl_player/utils/preview_image_cache.dart';
import 'package:pili_aurora/plugin/pl_player/utils/hardware_video_configuration.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_playback_runtime.dart';
import 'package:pili_aurora/plugin/pl_player/playback/super_resolution_policy.dart';
import 'package:pili_aurora/services/android_video_output_limit.dart';
import 'package:pili_aurora/plugin/pl_player/playback/network_recovery.dart';
import 'package:pili_aurora/plugin/pl_player/playback/audio_recovery.dart';
import 'package:pili_aurora/plugin/pl_player/playback/progress_projection.dart';
import 'package:pili_aurora/plugin/pl_player/playback/background_policy.dart';
import 'package:pili_aurora/plugin/pl_player/utils/playback_network_recovery.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';
import 'package:pili_aurora/services/desktop_playback_request.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/player_diagnostics.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/android/android_helper.dart';
import 'package:pili_aurora/utils/android/bindings.g.dart';
import 'package:pili_aurora/utils/asset_utils.dart';
import 'package:pili_aurora/utils/device_utils.dart';
import 'package:pili_aurora/utils/duration_utils.dart';
import 'package:pili_aurora/utils/extension/box_ext.dart';
import 'package:pili_aurora/utils/feed_back.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart' show HapticFeedback, DeviceOrientation;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

typedef PlayCallback = Future<void>? Function();

class PlPlayerController
    with BlockConfigMixin, AudioNormalizationMixin, WindowListener {
  late final NativePlaybackRuntime _runtime = NativePlaybackRuntime(
    configuration: _captureRuntimeConfiguration(),
    diagnosticsExtra: () => {
      'previewCacheBytes': previewCache.sizeBytes,
      'previewCacheLimitBytes': previewCache.maxBytes,
      'live': isLive,
      'appLifecycle': WidgetsBinding.instance.lifecycleState?.name,
      'session': {
        'phase': _session.currentSnapshot.phase.name,
        'stage': _session.currentSnapshot.stage.name,
        'runtimeId': _session.currentSnapshot.runtimeId,
        'requestId': _session.currentSnapshot.requestId,
        'loadId': _session.currentSnapshot.loadId,
        'playingIntent': _session.currentSnapshot.intent.playing,
        'seeking': _session.currentSnapshot.actual.seeking,
        'inhibitors': [
          for (final inhibitor in _session.currentSnapshot.inhibitors)
            inhibitor.source.name,
        ],
      },
      ..._runtime.videoFrameDiagnostics,
    },
  );
  PlayerDiagnostics? get _diagnostics => _runtime.diagnostics;
  Player? get _videoPlayerController => _runtime.player;
  VideoController? get _videoController => _runtime.videoController;

  static PlPlayerController? _instance;

  PlayerStatus playerStatus = .paused;

  final Rx<DataStatus> dataStatus = Rx(.none);

  Duration? seekToPos;
  bool hasToasted = false;
  final RxBool isSeeking = false.obs;

  final RxInt position = RxInt(0);
  final RxInt seekPosition = RxInt(0);
  final _progressProjection = PlaybackProgressProjection();
  int get progress => isSeeking.value ? seekPosition.value : position.value;

  int get positionInMilliseconds =>
      processing || _progressProjection.awaitingPosition
      ? position.value * 1000
      : videoPlayerController?.state.position.inMilliseconds ?? 0;

  final RxInt buffered = RxInt(0);

  final RxInt duration = RxInt(0);

  int durationInMilliseconds = 0;

  void updateDuration(Duration value) {
    duration.value = value.inSeconds;
    durationInMilliseconds = value.inMilliseconds;
  }

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;

  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  final RxDouble brightness = (-1.0).obs;

  final RxBool showControls = false.obs;

  final RxBool showBrightnessStatus = false.obs;

  final RxBool longPressStatus = false.obs;

  final RxBool controlsLock = false.obs;

  final RxBool isFullScreen = false.obs;
  final _isLive = false.obs;
  bool get isLive => _isLive.value;
  set isLive(bool value) => _isLive.value = value;

  bool _isVertical = false;

  final Rx<VideoFitType> videoFit = Rx(.contain);

  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  bool get wantsToPlay => _session.currentSnapshot.intent.playing;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  Timer? _timer;
  StreamSubscription? _subForSeek;
  Completer<void>? _seekCompletion;

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  // 长按倍速
  double get longPressSpeed => _longPressSpeed.value;

  /// [videoPlayerController] instance of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;
  ValueListenable<VideoController?> get videoControllerListenable =>
      _runtime.videoControllerListenable;
  PlaybackOwner? get activePlaybackOwner =>
      _activeOwner?.isActive == true ? _activeOwner : null;
  PlaybackFrameSource get frameSource => _runtime.frameSource;
  ValueListenable<bool> get videoFramePresented => _runtime.videoFramePresented;
  ValueListenable<bool> get videoDisplaySyncActive =>
      _runtime.videoDisplaySyncActive;
  double get playbackVolumePercent =>
      _session.currentSnapshot.configuration.desired.volume;

  final RxBool muted = DesktopPlaybackWindows.isPlayerWindow.obs;
  bool get isMuted => muted.value;

  Future<void> setMuted(bool value) async {
    muted.value = value;
    final owner = _activeOwner;
    if (owner != null && owner.isActive) {
      await owner.setVolume(value ? 0 : volumePercent(volume.value));
    }
    _audioRecovery?.onPlaybackChanged();
  }

  /// 听视频
  late final RxBool onlyPlayAudio = false.obs;

  Future<CommandResult> setOnlyAudio(bool value) {
    final owner = activePlaybackOwner;
    if (owner == null) return Future.value(const CommandResult.inactive());
    return owner.setAudioOnly(value);
  }

  Future<CommandResult> setPlayerVolumePercent(double value) {
    final owner = activePlaybackOwner;
    if (owner == null) return Future.value(const CommandResult.inactive());
    return owner.setVolume(value.clamp(0, 100).toDouble());
  }

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;
  final audioRecoveryStatus = AudioRecoveryStatus.idle.obs;
  final isVideoStalled = false.obs;

  /// 全屏方向
  // ignore: unnecessary_getters_setters
  bool get isVertical => _isVertical;

  set isVertical(bool value) {
    _isVertical = value;
  }

  /// 弹幕开关
  late final RxBool enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmakuAdaptive =>
      isLive ? enableShowLiveDanmaku : enableShowDanmaku;

  late final RxBool autoPipEnabled = Pref.autoPiP.obs;
  bool get autoPiP => autoPipEnabled.value;
  late final RxBool pauseOnMinimize = Pref.pauseOnMinimize.obs;
  PlaybackOwner? _minimizedWindowOwner;
  PlaybackInhibitorToken? _minimizedWindowToken;
  bool _listensToWindowEvents = false;

  void setAutoPiP(bool value) {
    if (!Platform.isAndroid) return;
    if (!value) _disableAutoEnterPip();
    autoPipEnabled.value = value;
    _isAutoEnterPip = value && DeviceUtils.sdkInt >= 31;
    if (_isAutoEnterPip && playerStatus.isPlaying) enterPip(autoEnter: true);
    if (!tempPlayerConf) setting.put(SettingBoxKey.autoPiP, value);
  }

  @override
  void onWindowMinimize() {
    if (!pauseOnMinimize.value || !playerStatus.isPlaying) return;
    final owner = activePlaybackOwner;
    if (owner == null) return;
    _minimizedWindowOwner = owner;
    _minimizedWindowToken ??= owner.acquireInhibitor(
      PlaybackInhibitorSource.system,
    );
  }

  @override
  void onWindowRestore() {
    final owner = _minimizedWindowOwner;
    final token = _minimizedWindowToken;
    _minimizedWindowOwner = null;
    _minimizedWindowToken = null;
    if (owner != null && token != null) {
      unawaited(owner.releaseInhibitor(token));
    }
  }

  bool get isPipMode =>
      (Platform.isAndroid && AndroidHelper.isPipMode) ||
      (PlatformUtils.isDesktop && isDesktopPip);
  bool get isDesktopPip => DesktopPlaybackWindows.isPlayerWindow;
  DesktopPlaybackRequest Function()? desktopPlaybackRequest;
  final _openingDesktopWindow = false.obs;
  bool get openingDesktopWindow => _openingDesktopWindow.value;
  bool _desktopWindowPresented = false;

  /// 播放页面已经布局当前媒体的有效纹理后，再交接窗口和声音。
  Future<void> notifyDesktopFramePresented(int loadId) async {
    final snapshot = currentPlaybackSnapshot;
    if (!isDesktopPip ||
        _desktopWindowPresented ||
        snapshot.loadId != loadId ||
        snapshot.phase != PlaybackPhase.ready ||
        snapshot.actual.playing != true ||
        (!onlyPlayAudio.value &&
            snapshot.capabilities.hasVideo != false &&
            !videoFramePresented.value)) {
      return;
    }
    _desktopWindowPresented = true;
    try {
      await DesktopPlaybackWindows.instance.playerReady();
    } catch (_) {
      DesktopPlaybackWindows.instance.playerFailed();
    }
  }

  late final RxBool isAlwaysOnTop = isDesktopPip.obs;
  Future<void> setAlwaysOnTop(bool value) {
    isAlwaysOnTop.value = value;
    return windowManager.setAlwaysOnTop(value);
  }

  Future<void> exitDesktopPip() => windowManager.close();

  Future<void> openDesktopWindow() async {
    if (openingDesktopWindow || desktopPlaybackRequest == null) return;
    _openingDesktopWindow.value = true;
    final owner = _activeOwner;
    try {
      await DesktopPlaybackWindows.instance.open(
        desktopPlaybackRequest!(),
        volume: volume.value,
      );
      if (owner != null && owner.isActive && identical(_activeOwner, owner)) {
        await owner.setPlaying(false);
      }
    } catch (_) {
      SmartDialog.showToast('播放窗口启动失败，请重试');
    } finally {
      _openingDesktopWindow.value = false;
    }
  }

  void toggleDesktopPip() {
    if (isDesktopPip) {
      exitDesktopPip();
    } else {
      openDesktopWindow();
    }
  }

  late bool _isAutoEnterPip = false;
  bool get isAutoEnterPip => _isAutoEnterPip;

  static bool get _isCurrVideoPage {
    final routing = Get.routing;
    if (routing.route is! GetPageRoute) {
      return false;
    }
    return _isVideoPage(routing.current);
  }

  static bool _isVideoPage(String routeName) {
    return routeName == '/videoV' || routeName == '/liveRoom';
  }

  void enterPip({bool autoEnter = false}) {
    if (videoPlayerController case NativePlayer(:final state)) {
      PageUtils.enterPip(
        autoEnter: autoEnter,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        isLive: isLive,
        isPlaying: playerStatus.isPlaying,
      );
    }
  }

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      PiliAndroidHelper.disableAutoEnterPip();
    }
  }

  // 弹幕相关配置
  bool get enableTapDm => PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter _filters = Pref.danmakuFilterRule;
  RuleFilter get filters => _filters;
  set filters(RuleFilter value) {
    _filters = value;
    for (final listener in _danmakuRuleListeners.toList()) {
      listener();
    }
  }

  final _danmakuRuleListeners = <VoidCallback>{};
  void addDanmakuRuleListener(VoidCallback listener) =>
      _danmakuRuleListeners.add(listener);
  void removeDanmakuRuleListener(VoidCallback listener) =>
      _danmakuRuleListeners.remove(listener);
  final _danmakuOptionsListeners = <VoidCallback>{};
  void addDanmakuOptionsListener(VoidCallback listener) =>
      _danmakuOptionsListeners.add(listener);
  void removeDanmakuOptionsListener(VoidCallback listener) =>
      _danmakuOptionsListeners.remove(listener);
  void notifyDanmakuOptionsChanged() {
    for (final listener in _danmakuOptionsListeners.toList()) {
      listener();
    }
  }

  void refreshDanmakuRules() {
    for (final listener in _danmakuRuleListeners.toList()) {
      listener();
    }
  }

  DanmakuDisplayBinding? danmakuDisplay;
  DanmakuInteractionHandle<DanmakuExtra>? get danmakuInteraction =>
      danmakuDisplay?.interaction();
  void clearDanmakuDisplay() => danmakuDisplay?.clear();

  final _showDanmaku = true.obs;
  bool get showDanmaku => _showDanmaku.value;
  set showDanmaku(bool value) {
    _showDanmaku.value = value;
    if (!value) clearDanmakuDisplay();
  }

  Set<int> dmState = <int>{};
  bool get mergeDanmaku => Pref.mergeDanmaku;
  late final String midHash = getCrc32(
    ascii.encode(Accounts.main.mid.toString()),
    0,
  ).toRadixString(16);
  late final RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;

  late List<double> speedList = Pref.speedList;
  late bool enableAutoLongPressSpeed = Pref.enableAutoLongPressSpeed;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  // 字幕
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpacity = Pref.subtitleBgOpacity;
  bool get showVipDanmaku => Pref.showVipDanmaku;
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardDuration = Duration(
    seconds: Pref.fastForBackwardDuration,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  bool get preInitPlayer => Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  bool get autoEnterFullScreen => Pref.autoEnterFullScreen;
  bool get autoExitFullscreen => Pref.autoExitFullscreen;
  bool get autoPlayEnable => Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  bool get tempPlayerConf => Pref.tempPlayerConf;

  late int? cacheVideoQa = PlatformUtils.isMobile ? null : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;
  bool _av1DecodeErrorObserved = false;
  AndroidDecodeRecovery? _androidDecodeRecovery;

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale => isRelative ? durationInMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle get subTitleStyle => TextStyle(
    height: 1.5,
    fontSize:
        16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[subtitleFontWeight],
    backgroundColor: subtitleBgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: subtitleBgOpacity),
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: subtitleBgOpacity == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : null,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaleFactor: 1,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    putSubtitleSettings();
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(
    PlayCallback? playCallBack, {
    Object? owner,
  }) {
    if (playCallBack == null) {
      if (owner == null || identical(_playCallBackOwner, owner)) {
        _playCallBack = null;
        _playCallBackOwner = null;
      }
      return;
    }
    _playCallBack = playCallBack;
    _playCallBackOwner = owner;
  }

  static PlayCallback? _playCallBack;
  static Object? _playCallBackOwner;

  static Future<void>? playIfExists() {
    return _playCallBack?.call();
  }

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus;
  }

  static Future<void>? pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) {
    if (_instance?.playerStatus.isPlaying ?? false) {
      return _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
    return null;
  }

  static Future<void>? seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) {
    return _instance?.seekTo(position, isSeek: isSeek);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void>? setVolumeIfExists(
    double volumeNew, {
    bool showIndicator = true,
  }) {
    return _instance?.setVolume(volumeNew, showIndicator: showIndicator);
  }

  Box video = GStorage.video;

  bool visible = true;

  DeviceOrientation? _orientation;
  late final checkIsAutoRotate = Platform.isAndroid && mode != .gravity;
  StreamSubscription<OrientationParams>? _orientationListener;

  void _stopOrientationListener() {
    _orientationListener?.cancel();
    _orientationListener = null;
  }

  void _onOrientationChanged(OrientationParams param) {
    _orientation = param.orientation;
    final orientation = param.orientation;
    final isFullScreen = this.isFullScreen.value;
    if (checkIsAutoRotate &&
        param.isAutoRotate != true &&
        (!isFullScreen ||
            _isVertical ||
            orientation == .portraitUp ||
            orientation == .portraitDown)) {
      return;
    }
    switch (orientation) {
      case .portraitUp:
        if (!_isVertical && controlsLock.value) return;
        if (!horizontalScreen && !_isVertical && isFullScreen) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode();
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        if (!_isVertical && controlsLock.value) return;
        portraitDownMode();
      case .landscapeLeft:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode();
        }
      case .landscapeRight:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeRightMode();
        }
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._() {
    if (isDesktopPip) {
      windowManager.addListener(this);
      _listensToWindowEvents = true;
    }
    if (PlatformUtils.isMobile) {
      _backgroundPolicy = PlaybackBackgroundPolicy(
        session: _session,
        continuePlaying: continuePlayInBackground.value,
      );
      _backgroundPolicySubscription = continuePlayInBackground.listen(
        (value) => _backgroundPolicy?.continuePlaying = value,
      );
      _orientationListener = NativeDeviceOrientationPlatform.instance
          .onOrientationChanged(
            checkIsAutoRotate: checkIsAutoRotate,
            angleDegrees: Platform.isAndroid ? Pref.angleDegrees : null,
          )
          .listen(_onOrientationChanged);
    }

    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    if (Platform.isAndroid) {
      if (DeviceUtils.sdkInt < 31) {
        final callback = Runnable.implement($Runnable(run: _onUserLeaveHint));
        AndroidHelper$ToDart.onUserLeaveHint = callback;
        callback.release();
      } else {
        _isAutoEnterPip = autoPiP;
      }
    }
    audioSessionHandler?.attachPlaybackController(this);
  }

  void _onUserLeaveHint() {
    if (autoPiP && playerStatus.isPlaying && _isCurrVideoPage) {
      enterPip();
    }
  }

  // 获取实例 传参
  static PlPlayerController getInstance({bool isLive = false}) {
    final current = _instance;
    if (current == null || current._session.isDisposed) {
      _instance = PlPlayerController._();
    }
    return _instance!..isLive = isLive;
  }

  late final PlaybackSession _session = PlaybackSession(runtime: _runtime);
  PlaybackMediaClock get mediaClock => _session;
  PlaybackNetworkRecovery? _networkRecovery;
  PlaybackAudioRecovery? _audioRecovery;
  PlaybackBackgroundPolicy? _backgroundPolicy;
  StreamSubscription<bool>? _backgroundPolicySubscription;
  bool _audioSeekInProgress = false;
  PlaybackOwner? _activeOwner;
  StreamSubscription<PlaybackSnapshot>? _snapshotSubscription;
  PlaybackPlan? _currentPlan;
  int? _shaderConfiguredLoadId;
  PlaybackOwner? _shaderPendingOwner;
  SuperResolutionType? _shaderPendingMode;
  int _shaderRequestGeneration = 0;

  PlaybackOwner attachPlaybackOwner() {
    final owner = _session.attach();
    activatePlaybackOwner(owner);
    return owner;
  }

  PlaybackKeepAliveLease? acquirePlaybackKeepAlive(PlaybackOwner owner) {
    final lease = owner.acquireKeepAlive();
    if (lease != null) _watchRuntimeRelease();
    return lease;
  }

  void closePlaybackOwner(PlaybackOwner owner) {
    owner.close();
    if (_session.isDisposed) _watchRuntimeRelease();
  }

  PlaybackInhibitorToken? acquireSessionInhibitor(
    PlaybackInhibitorSource source,
  ) => _session.acquireSessionInhibitor(source);

  Future<CommandResult> releaseSessionInhibitor(
    PlaybackInhibitorToken token,
  ) => _session.releaseSessionInhibitor(token);

  Future<PlaybackShutdownResult> shutdownPlaybackFacade() {
    _watchRuntimeRelease();
    return _session.shutdown();
  }

  Future<void> get playbackReleased => _runtime.released;

  bool _watchingRuntimeRelease = false;
  bool _facadeDisposed = false;
  int? _lastHandledActionId;
  int? _lastAcknowledgedActionId;
  final Set<int> _acknowledgingActionIds = {};

  void _watchRuntimeRelease() {
    if (_watchingRuntimeRelease) return;
    _watchingRuntimeRelease = true;
    unawaited(
      _runtime.released.then<void>(
        (_) => _disposeFacadeAfterRelease(),
        onError: (Object error, StackTrace stackTrace) {
          Utils.reportError(error, stackTrace);
          _disposeFacadeAfterRelease();
        },
      ),
    );
  }

  void _disposeFacadeAfterRelease() {
    if (_facadeDisposed) return;
    _facadeDisposed = true;
    if (_listensToWindowEvents) {
      windowManager.removeListener(this);
      _listensToWindowEvents = false;
      onWindowRestore();
    }
    _backgroundPolicy?.dispose();
    _backgroundPolicy = null;
    unawaited(_backgroundPolicySubscription?.cancel());
    _backgroundPolicySubscription = null;
    final ownsFacade = identical(_instance, this);
    _snapshotSubscription?.cancel();
    _snapshotSubscription = null;
    _networkRecovery?.dispose();
    _networkRecovery = null;
    _audioRecovery?.dispose();
    _audioRecovery = null;
    if (ownsFacade && removeSafeArea) showSystemBar();
    danmakuDisplay = null;
    _stopOrientationListener();
    if (ownsFacade) _disableAutoEnterPip();
    setPlayCallBack(null, owner: this);
    dmState.clear();
    if (showSeekPreview) _clearPreview();
    if (ownsFacade && Platform.isAndroid) {
      AndroidHelper$ToDart.onUserLeaveHint = null;
    }
    _timer?.cancel();
    volumeTimer?.cancel();
    if (ownsFacade && PlatformUtils.isDesktop && isAlwaysOnTop.value) {
      windowManager.setAlwaysOnTop(false);
    }
    _removeListeners();
    _positionListeners.clear();
    _coarsePositionListeners.clear();
    _statusListeners.clear();
    _lastCoarsePositionBucket = null;
    _stopWakeLockTimer();
    if (ownsFacade) {
      _setWakeLock(false);
      _instance = null;
      videoPlayerServiceHandler?.clear();
    }
  }

  void activatePlaybackOwner(PlaybackOwner owner) {
    owner.activate();
    if (identical(_activeOwner, owner)) return;
    _activeOwner = owner;
    unawaited(_snapshotSubscription?.cancel());
    _projectPlaybackSnapshot(_session.currentSnapshot, owner);
    _snapshotSubscription = owner.snapshots.listen(
      (snapshot) => _projectPlaybackSnapshot(snapshot, owner),
      onError: Utils.reportError,
    );
  }

  void _projectPlaybackSnapshot(
    PlaybackSnapshot snapshot,
    PlaybackOwner owner,
  ) {
    if (!owner.isActive || !identical(_activeOwner, owner)) return;
    final action = snapshot.pendingAction;
    var completedAction = false;
    if (action != null) {
      if (action.id != _lastHandledActionId) {
        _lastHandledActionId = action.id;
        completedAction = true;
        makeHeartBeat(-1, type: .completed);
      }
      if (action.ownerId == owner.id &&
          action.id != _lastAcknowledgedActionId &&
          _acknowledgingActionIds.add(action.id)) {
        unawaited(
          owner
              .acknowledgeAction(action)
              .then<void>(
                (result) {
                  _acknowledgingActionIds.remove(action.id);
                  if (result.outcome == CommandOutcome.applied ||
                      result.outcome == CommandOutcome.accepted) {
                    _lastAcknowledgedActionId = action.id;
                  }
                },
                onError: (Object error, StackTrace stackTrace) {
                  _acknowledgingActionIds.remove(action.id);
                  Utils.reportError(error, stackTrace);
                },
              ),
        );
      }
    }
    final player = _videoPlayerController;
    if (_subscriptions == null && player != null) _startListeners(player);
    final desired = snapshot.configuration.desired;
    _playbackSpeed.value = desired.playbackSpeed;
    onlyPlayAudio.value = desired.audioOnly;
    if (!isMuted && PlatformUtils.isDesktop) {
      volume.value = (desired.volume / 100).clamp(0.0, 1.0);
    }
    final wasBuffering = isBuffering.value;
    if ((snapshot.phase == PlaybackPhase.loading ||
            snapshot.phase == PlaybackPhase.recovering) &&
        !dataStatus.loading) {
      _progressProjection.begin(Duration(seconds: position.value));
    }
    if (snapshot.actual.buffering case final buffering?) {
      isBuffering.value = buffering;
    }
    if (snapshot.actual.duration case final actualDuration?
        when snapshot.phase == PlaybackPhase.ready &&
            actualDuration > Duration.zero) {
      updateDuration(actualDuration);
    }

    final wasLoading = dataStatus.loading;
    dataStatus.value = switch (snapshot.phase) {
      PlaybackPhase.idle => DataStatus.none,
      PlaybackPhase.loading || PlaybackPhase.recovering => DataStatus.loading,
      PlaybackPhase.ready || PlaybackPhase.ended => DataStatus.loaded,
      PlaybackPhase.failed => DataStatus.error,
      PlaybackPhase.closing || PlaybackPhase.disposed => DataStatus.none,
    };
    if (snapshot.phase == PlaybackPhase.ready && player != null) {
      _publishPlaybackPosition(player.state.position);
    }
    if (snapshot.phase == PlaybackPhase.ready &&
        snapshot.capabilities.hasAudio == true &&
        snapshot.actual.audioProgressing == false) {
      _ensureAudioRecovery()?.observe();
    }
    isVideoStalled.value =
        snapshot.phase == PlaybackPhase.ready &&
        snapshot.intent.playing &&
        snapshot.actual.playing == true &&
        snapshot.actual.seeking != true &&
        !desired.audioOnly &&
        snapshot.capabilities.hasVideo == true &&
        snapshot.actual.videoProgressing == false;
    if (isVideoStalled.value) {
      _recoverPlaybackNetwork(
        requireEmptyBuffer: false,
        allowNativeRecovery: false,
        requireVideoProgress: true,
      );
    }
    final loadId = snapshot.loadId;
    if (snapshot.phase == PlaybackPhase.ready &&
        loadId != null &&
        loadId != _shaderConfiguredLoadId) {
      _shaderConfiguredLoadId = loadId;
      unawaited(setShader());
    }
    final nextStatus = snapshot.phase == PlaybackPhase.ended
        ? PlayerStatus.completed
        : switch (snapshot.actual.playing) {
            true => PlayerStatus.playing,
            false => PlayerStatus.paused,
            null => playerStatus,
          };
    if (nextStatus == playerStatus) {
      if (wasBuffering != isBuffering.value ||
          wasLoading != dataStatus.loading) {
        _updatePlaybackState();
      }
      return;
    }
    playerStatus = nextStatus;
    _audioRecovery?.onPlaybackChanged();
    if (nextStatus.isPlaying) {
      _stopWakeLockTimer();
      _updatePlaybackState();
      _setWakeLock(true);
      if (_isAutoEnterPip) {
        if (_isCurrVideoPage) {
          enterPip(autoEnter: true);
        } else {
          _disableAutoEnterPip();
        }
      }
    } else {
      _startWakeLockTimer();
      _disableAutoEnterPip();
    }
    for (final listener in _statusListeners.toList()) {
      try {
        listener(nextStatus);
      } catch (error, stackTrace) {
        Utils.reportError(error, stackTrace);
      }
    }
    if (nextStatus.isCompleted && !completedAction) {
      makeHeartBeat(-1, type: .completed);
    } else if (snapshot.actual.position case final position?
        when position.inSeconds != 0) {
      makeHeartBeat(position.inSeconds, type: .status);
    }
  }

  bool get processing => _session.isLoading;
  String? get currentPlaybackContentKey => _currentPlan?.contentKey;
  PlaybackPlan? get currentPlaybackPlan {
    final loaded = _session.currentPlan;
    final plan =
        _session.currentSnapshot.phase == PlaybackPhase.ready &&
            loaded?.contentKey == _currentPlan?.contentKey
        ? loaded
        : _currentPlan;
    if (plan == null) return null;
    return plan.withConfiguration(
      _session.currentSnapshot.configuration.desired,
    );
  }

  PlaybackSnapshot get currentPlaybackSnapshot => _session.currentSnapshot;

  PlaybackRuntimeConfig _captureRuntimeConfiguration() {
    final enabled = Pref.enableHA;
    final decoder = Pref.hardwareDecoding;
    final playerOptions = <String, String>{
      'video-sync': Pref.videoSync,
      if (Platform.isWindows) 'gpu-dumb-mode': 'no',
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      'volume':
          (PlatformUtils.isMobile
                  ? Pref.playerVolume
                  : volumePercent(volume.value))
              .toString(),
      if (Pref.autosync != '0') 'autosync': Pref.autosync,
    };
    return PlaybackRuntimeConfig(
      playerOptions: playerOptions,
      hardwareAccelerationEnabled: enabled,
      hardwareDecoder: decoder,
      width: width,
      height: height,
      enableAndroidTextureScaling: Pref.enableAndroidTextureScaling,
      readAndroidTextureScaling: () => Pref.enableAndroidTextureScaling,
    );
  }

  PlaybackConfiguration capturePlaybackConfiguration({
    required bool live,
    DataSource? source,
    Volume? mediaVolume,
    bool? audioOnly,
  }) {
    final speed = live ? 1.0 : playbackSpeed;
    final options = (live ? Pref.initLiveBuffer() : Pref.initBuffer(speed))
      ..addAll({
        'video-sync': Pref.videoSync,
        'autosync': Pref.autosync,
      });
    // 先读取并固定归一化偏好；查询期间 Pref 的后续变化不影响本次计划。
    audioFilterExtras(null, map: <String, String>{});
    if (source?.audioSource?.isNotEmpty == true) {
      audioFilterExtras(mediaVolume, map: options);
    }
    final decoder = hardwareVideoConfiguration(
      enabled: Pref.enableHA,
      configured: Pref.hardwareDecoding,
    ).hwdec;
    return PlaybackConfiguration(
      audioOnly: audioOnly ?? onlyPlayAudio.value,
      playbackSpeed: speed,
      volume: isMuted
          ? 0
          : PlatformUtils.isMobile
          ? Pref.playerVolume
          : volumePercent(volume.value),
      hwdec: decoder ?? 'auto',
      mediaOptions: options,
    );
  }

  PlaybackPlan createPlaybackPlan({
    required String contentKey,
    required DataSource source,
    required PlaybackConfiguration configuration,
    required PlaybackTimelineKind timelineKind,
    required PlaybackSeekPolicy seekPolicy,
    Duration? duration,
    Duration? startPosition,
    Duration? reloadPosition,
    PlaybackMetadataHint? metadata,
    Volume? mediaVolume,
  }) {
    final options = Map<String, String>.of(configuration.mediaOptions)
      ..remove('lavfi-complex');
    if (source.audioSource?.isNotEmpty == true) {
      audioFilterExtras(mediaVolume, map: options);
    }
    return PlaybackPlan(
      contentKey: contentKey,
      source: PlaybackSourceSnapshot.fromDataSource(source),
      timeline: PlaybackTimeline(
        kind: timelineKind,
        seekPolicy: seekPolicy,
        duration: duration,
      ),
      configuration: configuration.copyWith(mediaOptions: options),
      startPosition: startPosition,
      reloadPosition: reloadPosition,
      metadata: metadata,
    );
  }

  void preparePlaybackPlan({
    required PlaybackOwner owner,
    required PlaybackPlan plan,
    required bool live,
    bool? isVertical,
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
  }) {
    if (!owner.isActive) return;
    final sameContent = _currentPlan?.contentKey == plan.contentKey;
    activatePlaybackOwner(owner);
    _networkRecovery?.dispose();
    _networkRecovery = null;
    _audioRecovery?.dispose();
    _audioRecovery = null;
    isLive = live;
    width = plan.metadata?.width;
    height = plan.metadata?.height;
    _videoType = videoType ?? VideoType.ugc;
    _androidDecodeRecovery?.reset();
    _cancelSubForSeek();
    _currentPlan = plan;
    _av1DecodeErrorObserved = false;
    dataStatus.value = DataStatus.loading;
    _isVertical = isVertical ?? false;
    _aid = aid;
    _bvid = bvid;
    this.cid = cid;
    _epid = epid;
    _seasonId = seasonId;
    _pgcType = pgcType;
    superResolutionType.value = isAnim
        ? Pref.superResolutionType
        : SuperResolutionType.disable;
    if (showSeekPreview) {
      _clearPreview();
    } else {
      _previewGeneration++;
    }
    cancelLongPressTimer();
    _heartDuration = 0;
    _lastCoarsePositionBucket = null;
    clearDanmakuDisplay();
    final metadataWidth = plan.metadata?.width;
    _shaderSourceSize.value = metadataWidth == null
        ? null
        : (
            width: metadataWidth,
            height: plan.metadata?.height ?? metadataWidth,
          );
    final initialPosition =
        plan.reloadPosition ??
        plan.startPosition ??
        (sameContent ? Duration(seconds: position.value) : Duration.zero);
    _progressProjection.begin(initialPosition);
    position.value = buffered.value = initialPosition.inSeconds;
    if (!sameContent || plan.timeline.duration != null) {
      updateDuration(plan.timeline.duration ?? Duration.zero);
    }
  }

  Future<LoadResult> loadPlaybackPlan({
    required PlaybackOwner owner,
    required PlaybackPlan plan,
    required PlaybackStartPolicy start,
    required bool live,
    bool? isVertical,
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
    VoidCallback? onReady,
    bool autoFullScreenFlag = false,
  }) async {
    preparePlaybackPlan(
      owner: owner,
      plan: plan,
      live: live,
      isVertical: isVertical,
      aid: aid,
      bvid: bvid,
      cid: cid,
      epid: epid,
      seasonId: seasonId,
      pgcType: pgcType,
      videoType: videoType,
    );
    final result = await owner.load(plan, start: start);
    if (!owner.isActive || !identical(_currentPlan, plan)) return result;
    switch (result.outcome) {
      case LoadOutcome.ready:
        _initVideoFit();
        if (autoFullScreenFlag && autoEnterFullScreen) {
          triggerFullScreen(status: true);
        }
        onReady?.call();
      case LoadOutcome.failed:
        dataStatus.value = DataStatus.error;
      case LoadOutcome.deferred:
        break;
      case LoadOutcome.noMedia:
      case LoadOutcome.superseded:
      case LoadOutcome.inactive:
      case LoadOutcome.closed:
        break;
    }
    return result;
  }

  void onPlaybackQueryReady({bool autoFullScreenFlag = false}) {
    _initVideoFit();
    if (autoFullScreenFlag && autoEnterFullScreen) {
      triggerFullScreen(status: true);
    }
  }

  // offline
  bool get isFileSource => _currentPlan?.source.isNetwork == false;
  FileSource? get currentFileSource => _currentPlan?.source.fileSource;

  String? shadersDirPath;
  Future<String> get copyShadersToExternalDirectory async {
    if (shadersDirPath != null) {
      return shadersDirPath!;
    }

    return shadersDirPath = await AssetUtils.getOrCopy(
      'assets/shaders',
      Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
      path.join(appSupportDirPath, 'anime_shaders'),
    );
  }

  bool get isAnim => _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;
  final _shaderSourceSize = Rxn<VideoOutputSize>();

  VideoOutputSize? get _shaderDisplaySize {
    final display =
        WidgetsBinding.instance.platformDispatcher.views.firstOrNull?.display;
    return (display == null
            ? null
            : VideoOutputSizePolicy.physicalDisplaySize(display.size)) ??
        (Platform.isAndroid ? AndroidVideoOutputLimit.detected : null);
  }

  SuperResolutionEligibility get superResolutionAvailability =>
      superResolutionEligibility(
        source: _shaderSourceSize.value,
        display: _shaderDisplaySize,
      );

  Future<void> setShader([SuperResolutionType? type]) async {
    final owner = _activeOwner;
    final requested = type ?? superResolutionType.value;
    final eligibility = superResolutionAvailability;
    // 显式选择在接触播放器前拒绝，保留当前档位和连续播放状态。
    if (type != null &&
        type != SuperResolutionType.disable &&
        eligibility != SuperResolutionEligibility.allowed) {
      return;
    }
    if (type != null && type == superResolutionType.value) return;
    final rejected =
        requested != SuperResolutionType.disable &&
        eligibility == SuperResolutionEligibility.resolutionTooHigh;
    final mode = rejected ? SuperResolutionType.disable : requested;
    superResolutionType.value = mode;
    if (rejected) {
      _diagnostics?.event(
        'shader.update.rejected',
        details: {
          'reason': 'source-exceeds-display',
          'source': _shaderSourceSize.value,
          'display': _shaderDisplaySize,
        },
      );
    } else if (type != null && isAnim && !tempPlayerConf) {
      setting.put(SettingBoxKey.superResolutionType, mode.index);
    }
    if (owner == null || !owner.isActive) return;
    if (identical(_shaderPendingOwner, owner) && _shaderPendingMode == mode) {
      return;
    }
    final requestGeneration = ++_shaderRequestGeneration;
    _shaderPendingOwner = owner;
    _shaderPendingMode = mode;
    final shaders = mode == SuperResolutionType.efficiency
        ? Assets.mpvAnime4KShadersLite
        : Assets.mpvAnime4KShaders;
    _diagnostics?.event(
      'shader.update.requested',
      details: {'mode': mode.name},
    );
    try {
      final List<String> paths;
      if (mode == SuperResolutionType.disable ||
          eligibility == SuperResolutionEligibility.unknownSize) {
        paths = const [];
      } else {
        final base = await copyShadersToExternalDirectory;
        paths = shaders.map((shader) => path.join(base, shader)).toList();
      }
      if (requestGeneration != _shaderRequestGeneration ||
          !owner.isActive ||
          !identical(owner, _activeOwner)) {
        return;
      }
      final currentShaders =
          _session.currentSnapshot.configuration.desired.shaders;
      if (_sameShaderPaths(currentShaders, paths)) return;
      await owner.setShader(paths);
      _diagnostics?.event(
        'shader.update.completed',
        details: {'mode': mode.name, 'shaderCount': paths.length},
      );
    } catch (error) {
      _diagnostics?.event(
        'shader.update.failed',
        level: DiagnosticLogLevel.warning,
        details: {'mode': mode.name, 'error': error},
      );
    } finally {
      if (requestGeneration == _shaderRequestGeneration) {
        _shaderPendingOwner = null;
        _shaderPendingMode = null;
      }
    }
  }

  bool _sameShaderPaths(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  Future<void>? refreshPlayer({
    bool tryNextCdn = false,
    bool automaticRecovery = false,
  }) {
    final owner = _activeOwner;
    final plan = currentPlaybackPlan;
    if (owner == null ||
        !owner.isActive ||
        plan == null ||
        !plan.source.isNetwork ||
        processing) {
      return null;
    }
    var reloadPlan = plan;
    final audioOnly = _session.currentSnapshot.configuration.desired.audioOnly;
    if (tryNextCdn && Pref.enableMultiCdn) {
      final next = plan.source.advanceCandidate(
        audioOnly: audioOnly,
      );
      if (next != null) {
        reloadPlan = plan.withSource(next);
        _currentPlan = reloadPlan;
      }
    }
    return () async {
      if (automaticRecovery) {
        await owner.recover(reloadPlan);
      } else if (identical(reloadPlan, plan)) {
        await owner.retry();
      } else {
        await owner.load(reloadPlan, start: PlaybackStartPolicy.preserve);
      }
    }();
  }

  void _recoverPlaybackNetwork({
    bool requireEmptyBuffer = true,
    bool allowNativeRecovery = true,
    bool waitForCachedPlayback = false,
    bool permissionDenied = false,
    bool requireVideoProgress = false,
  }) {
    final plan = currentPlaybackPlan;
    if (plan == null || !plan.source.isNetwork) return;
    final revision = _session.revision;
    if (_networkRecovery?.isActive == false) {
      _networkRecovery?.dispose();
      _networkRecovery = null;
    }
    _networkRecovery ??= PlaybackNetworkRecovery(
      isCurrent: () => _session.isCurrent(revision),
      readState: () {
        final player = _videoPlayerController;
        if (player == null ||
            player.disposed ||
            (!isLive && player.state.completed)) {
          return null;
        }
        return (
          buffering: isBuffering.value,
          position: player.state.position,
          buffer: player.state.buffer,
        );
      },
      reload: (tryNextCdn) => refreshPlayer(
        tryNextCdn: tryNextCdn,
        automaticRecovery: true,
      ),
      onError: Utils.reportError,
      videoProgressing: () {
        final snapshot = _session.currentSnapshot;
        return !snapshot.intent.playing ||
            snapshot.actual.playing != true ||
            snapshot.actual.seeking == true ||
            snapshot.actual.videoProgressing != false;
      },
      onRetry: () => SmartDialog.showToast(
        '视频链接打开失败，重试中',
        displayTime: const Duration(milliseconds: 500),
      ),
    );
    if (permissionDenied) {
      _networkRecovery!.stopForPermissionFailure();
      return;
    }
    _networkRecovery!.schedule(
      requireEmptyBuffer: !isLive && requireEmptyBuffer,
      allowNativeRecovery: allowNativeRecovery,
      waitForCachedPlayback: waitForCachedPlayback,
      tryNextCdn: true,
      candidate: Pref.enableMultiCdn ? plan.source.candidateIndex : 0,
      throttle: !isLive,
      requireVideoProgress: requireVideoProgress,
    );
  }

  void _observePlaybackAudio(PlayerLog event) {
    if (isFileSource ||
        (processing && !isPlaybackPermissionFailure(event.text))) {
      return;
    }
    if (event.level != 'error' && event.level != 'fatal') return;
    if (event.prefix != 'ffmpeg/audio' &&
        event.prefix != 'ad' &&
        !isPlaybackPermissionFailure(event.text) &&
        !isPlaybackStreamReadFailure(
          prefix: event.prefix,
          level: event.level,
          message: event.text,
        )) {
      return;
    }
    final recovery = _ensureAudioRecovery();
    recovery?.onLog(
      prefix: event.prefix,
      level: event.level,
      message: event.text,
    );
  }

  PlaybackAudioRecovery? _ensureAudioRecovery() {
    if (isFileSource) return null;
    final plan = _currentPlan;
    if (plan == null ||
        (plan.source.currentAudioSource?.isNotEmpty != true &&
            _videoPlayerController?.state.tracks.audio.any(
                  (track) => int.tryParse(track.id) != null,
                ) !=
                true)) {
      return null;
    }
    final revision = _session.revision;
    if (_audioRecovery?.isActive == false) {
      _audioRecovery?.dispose();
      _audioRecovery = null;
    }
    _audioRecovery ??= PlaybackAudioRecovery(
      readState: () {
        final player = _videoPlayerController;
        if (!_session.isCurrent(revision) ||
            player == null ||
            player.disposed ||
            player.current.isEmpty) {
          return null;
        }
        return (
          playing:
              player.state.playing &&
              wantsToPlay &&
              !isMuted &&
              volume.value > 0,
          waiting:
              processing ||
              _audioSeekInProgress ||
              isSeeking.value ||
              player.state.buffering ||
              _diagnostics?.property('seeking') == 'yes',
          completed:
              player.state.completed ||
              _diagnostics?.property('eof-reached') == 'yes',
          position: player.state.position,
          duration: player.state.duration,
          audioPts: double.tryParse(_diagnostics?.property('audio-pts') ?? ''),
          audioDelay:
              double.tryParse(
                _diagnostics?.property('audio-delay') ?? '',
              ) ??
              0,
        );
      },
      repairAudio: () {
        if (processing) return null;
        final owner = _activeOwner;
        if (owner == null || !owner.isActive) return Future.value(false);
        return owner.reloadAudio().then(
          (result) => result.outcome == CommandOutcome.applied,
        );
      },
      reload: () => refreshPlayer(
        tryNextCdn: true,
        automaticRecovery: true,
      ),
      onDiagnostic: (action) => _diagnostics?.event(
        action,
        level: DiagnosticLogLevel.warning,
      ),
      onStatusChanged: (status) {
        audioRecoveryStatus.value = status;
        _updatePlaybackState();
      },
      onError: (error) => _diagnostics?.event(
        'audio.recovery.failed',
        level: DiagnosticLogLevel.warning,
        details: {'error': error},
      ),
      onExhausted: () => SmartDialog.showToast('声音恢复失败，可尝试重新播放'),
    );
    return _audioRecovery;
  }

  // 首次加载倍速、shader 与音轨配置均随 PlaybackPlan 提交。

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<Duration>> _coarsePositionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};
  int? _lastCoarsePositionBucket;

  Timer? _wakeLockTimer;
  bool _wakeLockHeld = false;
  bool _wakeLockWanted = false;
  Future<void> _wakeLockOperations = Future<void>.value();

  void _setWakeLock(bool enabled) {
    _wakeLockWanted = enabled;
    _wakeLockOperations = _wakeLockOperations.then((_) async {
      while (_wakeLockHeld != _wakeLockWanted) {
        final next = _wakeLockWanted;
        try {
          if (next) {
            await WakelockPlus.enable();
          } else {
            await WakelockPlus.disable();
          }
          _wakeLockHeld = next;
        } catch (error, stackTrace) {
          Utils.reportError(error, stackTrace);
          _wakeLockWanted = _wakeLockHeld;
        }
      }
    });
    unawaited(_wakeLockOperations);
  }

  void _startWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = Timer(
      const Duration(milliseconds: 500),
      _stopWakeLock,
    );
  }

  void _stopWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = null;
  }

  void _stopWakeLock() {
    _setWakeLock(false);
    _updatePlaybackState(debugLabel: 'onVideoPaused');
  }

  void _updatePlaybackState({Duration? position, String? debugLabel}) {
    final player = _videoPlayerController;
    if (player == null) return;
    videoPlayerServiceHandler?.onUpdateState(
      playerStatus,
      isBuffering.value,
      isLive,
      position: position ?? player.state.position,
      speed: playbackSpeed,
      loading:
          dataStatus.loading ||
          isVideoStalled.value ||
          audioRecoveryStatus.value == AudioRecoveryStatus.recovering,
      debugLabel: debugLabel,
    );
  }

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    if (Platform.isAndroid) {
      _androidDecodeRecovery = AndroidDecodeRecovery(
        readState: () {
          if (player.disposed || player.current.isEmpty) return null;
          return (
            decoder: _diagnostics?.property('hwdec-current'),
            playing: player.state.playing,
            buffering: player.state.buffering,
            seeking: _diagnostics?.property('seeking') == 'yes',
            completed: player.state.completed,
            eof: _diagnostics?.property('eof-reached') == 'yes',
            videoPts: double.tryParse(
              _diagnostics?.property('video-pts') ?? '',
            ),
          );
        },
        applyDecoder: (decoder) {
          _diagnostics?.event(
            'decoder.apply.begin',
            level: DiagnosticLogLevel.warning,
            details: {'requestedDecoder': decoder},
          );
          final owner = _activeOwner;
          if (owner != null && owner.isActive) {
            unawaited(
              owner.setDecoder(
                PlaybackDecoder(decoder, kind: PlaybackDecoderKind.hardware),
              ),
            );
          }
          _diagnostics?.event(
            'decoder.apply.accepted',
            level: DiagnosticLogLevel.warning,
            details: {'requestedDecoder': decoder},
          );
          Diagnostics.instance.playerLog(
            DiagnosticLogLevel.warning,
            'player',
            'Android video output recovery: hwdec=$decoder',
          );
        },
        onFallback: (_) {
          SmartDialog.showToast(
            '正在切换解码...',
            displayTime: const Duration(seconds: 2),
          );
        },
        recoverSoftware: () async {
          if (isLive || isFileSource) return false;
          final reload = refreshPlayer();
          if (reload == null) return false;
          Diagnostics.instance.playerLog(
            DiagnosticLogLevel.warning,
            'player',
            'Android AV1 software recovery: reload current media once',
          );
          await reload;
          return true;
        },
        onDiagnostic: (action, details) => _diagnostics?.event(
          action,
          level: action.contains('failed')
              ? DiagnosticLogLevel.error
              : DiagnosticLogLevel.debug,
          details: details,
        ),
        onError: (error) {
          _diagnostics?.event(
            'decoder.recovery.failed',
            level: DiagnosticLogLevel.error,
            details: {'error': error},
          );
          Utils.reportError(error);
        },
      );
    }
    _subscriptions = [
      stream.videoParams.listen((params) {
        final source = VideoOutputSizePolicy.videoDisplaySize(params);
        if (source == null || source == _shaderSourceSize.value) return;
        _shaderSourceSize.value = source;
        if (superResolutionType.value != SuperResolutionType.disable) {
          setShader();
        }
      }),
      player.observeProperty('seeking').listen((_) {
        _audioRecovery?.onPlaybackChanged();
      }),
      stream.log.listen((event) {
        if (isPlaybackPermissionFailure(event.text)) {
          _recoverPlaybackNetwork(permissionDenied: true);
        }
        _observePlaybackAudio(event);
        _androidDecodeRecovery?.onLog(
          prefix: event.prefix,
          level: event.level,
          message: event.text,
        );
        // curl / ffmpeg/demuxer 的错误保留在原始日志流中，不进入 stream.error。
        if (isPlaybackStreamReadFailure(
          prefix: event.prefix,
          level: event.level,
          message: event.text,
        )) {
          _recoverPlaybackNetwork(
            requireEmptyBuffer: false,
            waitForCachedPlayback:
                !onlyPlayAudio.value &&
                _currentPlan?.source.currentAudioSource?.isNotEmpty == true,
          );
        }
      }),

      /// playing
      stream.playing.listen((bool playing) {
        _audioRecovery?.onPlaybackChanged();
      }),

      ///completed
      stream.completed.listen((_) {}),

      /// position
      stream.position.listen(_publishPlaybackPosition),
      stream.duration.listen((value) {
        if (!processing && value > Duration.zero) updateDuration(value);
      }),
      stream.buffer.listen((Duration buffer) {
        if (!processing && !_progressProjection.awaitingPosition) {
          buffered.value = buffer.inSeconds;
        }
      }),
      stream.buffering.listen((bool buffering) {
        _audioRecovery?.onPlaybackChanged();
        if (buffering && !processing) _recoverPlaybackNetwork();
      }),
      stream.error.listen((String event) {
        // PlayerDiagnostics owns error logging, including its native state snapshot.
        if (isFileSource && event.startsWith("Failed to open file")) {
          return;
        }
        if (event.toLowerCase().contains('av1')) {
          _av1DecodeErrorObserved = true;
        }
        if (_av1DecodeErrorObserved && isHardwareDecodeFailure(event)) {
          // mpv 继续执行完整候选列表；避免同时重开媒体或上报已处理的回退错误。
          return;
        }
        if (event == 'Error decoding audio.' && !isFileSource) {
          // 原始 ad 日志已进入音轨恢复，避免同时重载视频或弹出异常报告。
          return;
        }
        if (isLive) {
          if (isPlaybackNetworkFailure(event)) {
            _recoverPlaybackNetwork();
          }
          return;
        }
        if (isPlaybackNetworkFailure(event)) {
          _recoverPlaybackNetwork();
        } else if (event.startsWith('Could not open codec')) {
          SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          if (!kDebugMode) {
            Utils.reportError('$event\n${player.state.playlist}');
          }
          // SmartDialog.showToast('视频加载错误, $event');
        }
      }),
    ];
  }

  void _publishPlaybackPosition(Duration value) {
    if (_audioSeekInProgress) return;
    if (!_progressProjection.accept(_session.currentSnapshot.phase, value)) {
      return;
    }
    final seconds = value.inSeconds;
    if (position.value != seconds) {
      position.value = seconds;
      makeHeartBeat(seconds);
    }
    for (final listener in _positionListeners) {
      listener(value);
    }
    final bucket = value.inMilliseconds ~/ 100;
    if (bucket != _lastCoarsePositionBucket) {
      _lastCoarsePositionBucket = bucket;
      for (final listener in _coarsePositionListeners) {
        listener(value);
      }
    }
  }

  /// 移除事件监听
  void _removeListeners() {
    _androidDecodeRecovery?.dispose();
    _androidDecodeRecovery = null;
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
  }

  void _cancelSubForSeek() {
    final completion = _seekCompletion;
    _seekCompletion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
    if (_subForSeek != null) {
      _subForSeek!.cancel();
      _subForSeek = null;
    }
  }

  Future<void> seek(Duration position, {bool isSeek = false}) async {
    _progressProjection.begin(position);
    _audioSeekInProgress = true;
    _audioRecovery?.onPlaybackChanged();
    danmakuDisplay?.seeking?.call();
    final watch = Stopwatch()..start();
    _diagnostics?.event(
      'playback.seek.begin',
      level: DiagnosticLogLevel.debug,
      details: {'targetMs': position.inMilliseconds, 'dragSeek': isSeek},
    );
    try {
      final owner = _activeOwner;
      if (owner == null || !owner.isActive) return;
      final result = await owner.seek(position);
      if (result.outcome != CommandOutcome.applied) {
        if (_videoPlayerController case final player?) {
          _progressProjection.begin(player.state.position);
        }
      }
      _diagnostics?.event(
        result.outcome == CommandOutcome.applied
            ? 'playback.seek.end'
            : 'playback.seek.notApplied',
        level: DiagnosticLogLevel.debug,
        details: {
          'targetMs': position.inMilliseconds,
          'durationUs': watch.elapsedMicroseconds,
        },
      );
    } catch (e, stack) {
      _diagnostics?.event(
        'playback.seek.failed',
        level: DiagnosticLogLevel.error,
        details: {
          'error': e,
          'stack': stack,
          'targetMs': position.inMilliseconds,
        },
      );
    } finally {
      _audioSeekInProgress = false;
      if (_videoPlayerController case final player?) {
        _publishPlaybackPosition(player.state.position);
      }
      _audioRecovery?.onPlaybackChanged();
    }
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    _cancelSubForSeek();
    final owner = _activeOwner;
    if (owner == null || !owner.isActive) return;
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    _heartDuration = position.inSeconds;

    if (duration.value != 0) {
      await seek(position, isSeek: isSeek);
    } else {
      final plan = _currentPlan;
      final completion = _seekCompletion = Completer<void>();
      _subForSeek = duration.listen((value) {
        if (value <= 0) return;
        _subForSeek?.cancel();
        _subForSeek = null;
        _seekCompletion = null;
        if (!owner.isActive || !identical(plan, _currentPlan)) {
          completion.complete();
          return;
        }
        seek(
          position,
          isSeek: isSeek,
        ).then(completion.complete, onError: completion.completeError);
      });
      await completion.future;
    }
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    final owner = _activeOwner;
    if (owner == null || !owner.isActive) return;
    lastPlaybackSpeed = playbackSpeed;
    final previousSpeed = playbackSpeed;
    if (speed == previousSpeed) return;
    final options = Map<String, String>.of(
      _session.currentSnapshot.configuration.desired.mediaOptions,
    );
    if (!isLive &&
        _currentPlan?.source.isNetwork == true &&
        previousSpeed > 0) {
      final ratio = speed / previousSpeed;
      for (final name in ['cache-secs', 'demuxer-hysteresis-secs']) {
        final value = double.tryParse(options[name] ?? '');
        if (value != null) options[name] = (value * ratio).toStringAsFixed(3);
      }
    }
    await owner.setPlaybackSpeed(speed, mediaOptions: options);
  }

  // 还原默认速度
  double playSpeedDefault = Pref.playSpeedDefault;
  Future<void> setDefaultSpeed() async {
    await setPlaybackSpeed(playSpeedDefault);
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    final owner = _activeOwner;
    if (owner == null || !owner.isActive) return;
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      await owner.seek(Duration.zero);
    }
    await owner.setPlaying(true);

    audioSessionHandler?.setActive(true);
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    final owner = _activeOwner;
    if (owner == null || !owner.isActive || !notify) return;
    await owner.setPlaying(false);

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;
  bool controlsMenuOpen = false;

  void setControlsMenuOpen(bool value) {
    controlsMenuOpen = value;
    if (value) {
      controls = true;
      _timer?.cancel();
    } else {
      hideTaskControls();
    }
  }

  /// 隐藏控制条
  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSeeking.value && !tripling && !controlsMenuOpen) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onSeekStart(int seekFrom) {
    seekPosition.value = seekFrom;
    isSeeking.value = true;
    _audioRecovery?.onPlaybackChanged();
  }

  void onSeekEnd() {
    if (showSeekPreview) {
      showPreview.value = false;
    }
    hasToasted = false;
    isSeeking.value = false;
    _audioRecovery?.onPlaybackChanged();
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  final double maxVolume = 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    volume = roundVolumeRatio(volume.clamp(0.0, maxVolume));
    final changed = this.volume.value != volume;
    this.volume.value = volume;
    if (changed || isMuted) {
      muted.value = false;
      try {
        final owner = _activeOwner;
        if (owner != null && owner.isActive) {
          await owner.setVolume(volumePercent(volume));
        }
        if (PlatformUtils.isMobile) {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err, stackTrace) {
        logger.w(err.toString(), error: err, stackTrace: stackTrace);
      }
      _audioRecovery?.onPlaybackChanged();
    }
    if (showIndicator) {
      volumeIndicator.value = true;
    }
    volumeInterceptEventStream = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream = false;
      if (PlatformUtils.isDesktop) {
        setting.put(
          SettingBoxKey.desktopVolume,
          roundVolumeRatio(volume),
        );
      }
    });
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit(VideoFitType value) {
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
  }

  /// 读取fit
  var _prefFit = VideoFitType.values[Pref.cacheVideoFit];
  void _initVideoFit() {
    if (_prefFit == .fill && _isVertical) {
      videoFit.value = .contain;
    } else {
      videoFit.value = _prefFit;
    }
  }

  /// 设置后台播放
  void setBackgroundPlay(bool val) {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    // 浮层会使画面收到鼠标离开事件；菜单操作期间保持锚点所在的控件栏可见。
    if (!visible && controlsMenuOpen) return;
    showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  /// 设置长按倍速状态 live模式下禁用
  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    if (longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (playerStatus.isPlaying) {
        longPressStatus.value = val;
        HapticFeedback.lightImpact();
        await setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
        );
      }
    } else {
      // if (kDebugMode) debugPrint('$playbackSpeed');
      longPressStatus.value = val;
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  bool get isCompleted =>
      videoPlayerController!.state.completed ||
      durationInMilliseconds - positionInMilliseconds <= 50;

  // 双击播放、暂停
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await seekTo(Duration.zero, isSeek: false);
      await play();
    } else if (playerStatus.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position - duration);
  }

  void onForwardBackward(Duration duration) {
    seekTo(
      duration.clamp(Duration.zero, videoPlayerController!.state.duration),
      isSeek: false,
    );
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        // 双击左边区域 👈
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        // 双击右边区域 👈
        onDoubleTapSeekForward();
        break;
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    controlsLock.value = val;
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val) {
    isFullScreen.value = val;
    updateSubtitleStyle();
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  late final horizontalScreen = Pref.horizontalScreen;
  late final removeSafeArea = Pref.removeSafeArea;

  Future<void>? changeOrientation({
    required bool isVertical,
    DeviceOrientation? orientation,
  }) {
    if (orientation == null && (mode == .none || mode == .gravity)) {
      return null;
    }
    if (orientation == null &&
        (mode == .vertical ||
            (mode == .auto && isVertical) ||
            (mode == .ratio && (isVertical || screenRatio < kScreenRatio)))) {
      return portraitUpMode();
    } else {
      // https://github.com/flutter/flutter/issues/73651
      // https://github.com/flutter/flutter/issues/183708
      if (Platform.isAndroid) {
        if ((orientation ?? _orientation) == .landscapeRight) {
          return landscapeRightMode();
        } else {
          return landscapeLeftMode();
        }
      } else {
        if (orientation == .landscapeLeft) {
          return landscapeLeftMode();
        } else {
          return landscapeRightMode();
        }
      }
    }
  }

  // 全屏
  bool _fsProcessing = false;
  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isFullScreen.value == status) return;

    if (_fsProcessing) return;
    _fsProcessing = true;
    this.isManualFS = isManualFS;
    try {
      if (isDesktopPip) {
        await windowManager.setFullScreen(status);
      } else if (status) {
        if (PlatformUtils.isMobile) {
          hideSystemBar();
          await changeOrientation(
            isVertical: isVertical,
            orientation: orientation,
          );
        } else {
          await enterDesktopFullScreen(inAppFullScreen: inAppFullScreen);
        }
      } else {
        if (PlatformUtils.isMobile) {
          if (!removeSafeArea) {
            showSystemBar();
          }
          if (orientation == null && mode == .none) {
            return;
          }
          await resetScreenRotation();
        } else {
          await exitDesktopFullScreen();
        }
      }
    } finally {
      _setFullScreen(status);
      _fsProcessing = false;
    }
  }

  void addPositionListener(ValueChanged<Duration> listener) {
    if (_activeOwner?.isActive != true) return;
    _positionListeners.add(listener);
  }

  void addCoarsePositionListener(ValueChanged<Duration> listener) {
    if (_activeOwner?.isActive != true) return;
    _coarsePositionListeners.add(listener);
  }

  void removePositionListener(ValueChanged<Duration> listener) {
    _positionListeners.remove(listener);
    _coarsePositionListeners.remove(listener);
  }

  void removeCoarsePositionListener(ValueChanged<Duration> listener) {
    _coarsePositionListeners.remove(listener);
  }

  void addStatusLister(ValueChanged<PlayerStatus> listener) {
    if (_activeOwner?.isActive != true) return;
    _statusListeners.add(listener);
  }

  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      _statusListeners.remove(listener);

  // 记录播放记录
  Future<void>? makeHeartBeat(
    int progress, {
    HeartBeatType type = .playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) {
    if (isLive ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      return null;
    }

    Future<void> send() {
      return VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }

    switch (type) {
      case .playing:
        if (progress - _heartDuration >= 5) {
          _heartDuration = progress;
          return send();
        }
      case .status:
        if (progress - _heartDuration >= 2) {
          _heartDuration = progress;
          return send();
        }
      case .completed:
        if (playerStatus.isCompleted &&
            (durationInMilliseconds - positionInMilliseconds) <= 1000) {
          progress = -1;
        }
        return send();
    }
    return null;
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    if (!tempPlayerConf) video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putSubtitleSettings() {
    setting.putAllNE({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpacity: subtitleBgOpacity,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool _isCloseAll = false;
  bool get isCloseAll => _isCloseAll;

  Future<void>? resetScreenRotation() {
    if (horizontalScreen) {
      return fullMode();
    } else {
      return portraitUpMode();
    }
  }

  void onCloseAll() {
    _isCloseAll = true;
    if (PlatformUtils.isDesktop) exitDesktopFullScreen();
    Get.until((route) => route.isFirst);
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.toggle();
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
  }

  late final previewCache = PreviewImageCache();
  LoadingState<VideoShotData>? videoShot;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();
  int _previewGeneration = 0;

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success(:final response)) {
      if (!showPreview.value) {
        showPreview.value = true;
      }
      final index = response.index;
      var low = 0;
      var high = index.length;
      while (low < high) {
        final middle = (low + high) ~/ 2;
        if (index[middle] <= seconds) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      final nextIndex = max(0, low - 2);
      if (previewIndex.value != nextIndex) {
        previewIndex.value = nextIndex;
      }
    }
  }

  void _clearPreview() {
    _previewGeneration++;
    showPreview.value = false;
    previewIndex.value = null;
    videoShot = null;
    previewCache.clear();
  }

  Future<void> getVideoShot() async {
    final generation = _previewGeneration;
    final requestBvid = bvid;
    final requestCid = cid!;
    final result = await VideoHttp.videoshot(
      bvid: requestBvid,
      cid: requestCid,
    );
    if (generation == _previewGeneration &&
        requestBvid == _bvid &&
        requestCid == cid) {
      videoShot = result;
    }
  }

  bool _takingScreenshot = false;
  Future<void> takeScreenshot() async {
    if (_takingScreenshot) return;
    _takingScreenshot = true;
    try {
      await _showScreenshot();
    } finally {
      _takingScreenshot = false;
    }
  }

  Future<void> _showScreenshot() async {
    SmartDialog.showToast('截图中');
    final image = await videoPlayerController?.screenshot();
    if (image != null) {
      Future<void>? saveTask;
      SmartDialog.showToast('点击弹窗保存截图');
      try {
        await showDialog<void>(
          context: Get.context!,
          builder: (context) => GestureDetector(
            onTap: () {
              if (saveTask != null) return;
              saveTask = () async {
                try {
                  final bytes = await image.toByteData(format: .png);
                  if (bytes != null) {
                    final time = DurationUtils.formatDuration(
                      positionInMilliseconds / 1000,
                    ).replaceAll(':', '-');
                    await ImageUtils.saveByteImg(
                      bytes: bytes.buffer.asUint8List(),
                      fileName: 'screenshot_${cid}_$time',
                    );
                  } else {
                    SmartDialog.showToast('保存失败');
                  }
                } catch (error, stackTrace) {
                  logger.w('保存截图失败', error: error, stackTrace: stackTrace);
                  SmartDialog.showToast('保存失败');
                } finally {
                  if (context.mounted) Navigator.of(context).pop();
                }
              }();
            },
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: min(MediaQuery.widthOf(context) / 3, 350),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        width: 5,
                        color: ColorScheme.of(context).surface,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: RawImage(image: image),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      } finally {
        try {
          await saveTask;
        } finally {
          image.dispose();
        }
      }
    } else {
      SmartDialog.showToast('截图失败');
    }
  }

  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      if (playerStatus.isPlaying) {
        pause();
      }

      if (Platform.isAndroid) {
        _disableAutoEnterPip();
        if (!setSystemBrightness) {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      }

      return;
    }

    if (controlsLock.value) {
      onLockControl(false);
      return;
    }
    if (isFullScreen.value) {
      triggerFullScreen(status: false);
      return;
    }
    if (isDesktopPip) {
      exitDesktopPip();
      return;
    }
    Get.back();
  }
}

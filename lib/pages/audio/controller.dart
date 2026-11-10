import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show listEquals;

import 'package:pili_aurora/utils/volume_utils.dart';
import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/common/widgets/dialog/simple_dialog_option.dart';
import 'package:pili_aurora/grpc/audio.dart';
import 'package:pili_aurora/grpc/bilibili/app/listener/v1.pb.dart'
    show
        DetailItem,
        PlayURLResp,
        PlaylistSource,
        PlayInfo,
        ThumbUpReq_ThumbType,
        ListOrder,
        DashItem,
        ResponseUrl;
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/audio_normalization.dart';
import 'package:pili_aurora/models/video/play/url.dart'
    as http_model
    show Volume;
import 'package:pili_aurora/pages/common/common_intro_controller.dart'
    show FavMixin;
import 'package:pili_aurora/pages/dynamics_repost/view.dart';
import 'package:pili_aurora/pages/main_reply/view.dart';
import 'package:pili_aurora/pages/sponsor_block/block_mixin.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/widgets/triple_mixin.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_repeat.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart'
    show CommandOutcome;
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/services/audio_session.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/services/shutdown_timer_service.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/android/android_helper.dart';
import 'package:pili_aurora/utils/connectivity_utils.dart';
import 'package:pili_aurora/utils/extension/iterable_ext.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/share_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:pili_aurora/utils/video_utils.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

class AudioController extends GetxController
    with
        GetTickerProviderStateMixin,
        TripleMixin,
        FavMixin,
        BlockConfigMixin,
        BlockMixin,
        AudioNormalizationMixin {
  AudioController({Future<Player> Function(PlayerConfiguration)? createPlayer})
    : _createPlayer =
          createPlayer ??
          ((configuration) => Player.create(configuration: configuration));

  final Future<Player> Function(PlayerConfiguration) _createPlayer;

  late Int64 id;
  late Int64 oid;
  late List<Int64> subId;
  late int itemType;
  Int64? extraId;
  late final PlaylistSource from;
  @override
  bool get isUgc => itemType == 1;

  final audioItem = Rxn<DetailItem>();

  int _playlistGeneration = 0;
  Account? _playlistAccount;
  bool _listeningToPlaylistAccount = false;
  Object? _pageOperation;
  bool _failedPageIsPrev = false;
  int _prevEmptyPages = 0;
  int _nextEmptyPages = 0;
  final playlistState = Rx<LoadingState<void>>(LoadingState.loading());
  final playlistPageState = Rx<LoadingState<void>>(const Success(null));
  final playlistRevision = RxInt(0);
  final _removedPlaylistItems = <(int, Int64)>{};
  int _playGeneration = 0;
  Account? _playAccount;
  bool _playbackReady = false;
  int? _pendingPlayGeneration;
  Future<void>? _playerInitialization;
  Future<bool>? _mediaOpening;
  bool _audioClosed = false;
  int _speedRevision = 0;
  int _volumeRevision = 0;
  int _seekRevision = 0;
  @override
  Player? player;
  Player? _closingPlayer;
  IndependentAudioLease? _audioLease;

  void _ensureAudioLease() {
    _audioLease ??= audioSessionHandler?.acquireIndependentPlayer(
      setPlaying: (playing) async {
        final target = player;
        if (target == null) return;
        if (playing) {
          await target.play();
        } else {
          await target.pause();
        }
      },
      volume: () => player?.state.volume ?? 0,
      volumeRevision: () => _volumeRevision,
      setVolume: (value) async {
        _volumeRevision++;
        await player?.setVolume(value);
      },
    );
  }

  late int cacheAudioQa;

  late bool isDragging = false;
  final RxInt position = RxInt(0);
  final RxInt duration = RxInt(0);

  late final AnimationController animController;

  List<StreamSubscription>? _subscriptions;

  int? index;
  List<DetailItem>? playlist;

  late double speed = 1.0;

  bool _ownsControl(Player? target, int generation, Account account) =>
      !_audioClosed &&
      !isClosed &&
      identical(player, target) &&
      generation == _playGeneration &&
      identical(account, Accounts.main);

  Player get _readyPlayer => player ?? (throw StateError('音频播放器尚未就绪'));

  void _reportControlFailure(String message, Object error, StackTrace stack) {
    logger
        .scoped('audio')
        .w(message, error: error.runtimeType, stackTrace: stack);
    SmartDialog.showToast(message);
  }

  Future<bool> setSpeed(double value) async {
    final target = player;
    final generation = _playGeneration;
    final account = Accounts.main;
    final revision = ++_speedRevision;
    try {
      await _readyPlayer.setRate(value);
      if (!_ownsControl(target, generation, account) ||
          revision != _speedRevision) {
        return false;
      }
      speed = value;
      _updatePlaybackState();
      return true;
    } catch (error, stack) {
      if (_ownsControl(target, generation, account) &&
          revision == _speedRevision) {
        _reportControlFailure('播放速度调整失败，请重试', error, stack);
      }
      return false;
    }
  }

  late final Rx<PlayRepeat> playMode = Pref.audioPlayMode.obs;

  @override
  bool get isLogin => Accounts.main.isLogin;

  Duration? _start;
  VideoDetailController? _videoDetailController;

  String? _prev;
  String? _next;
  bool get reachStart => _prev == null;
  bool get hasNextPage => _next != null;

  ListOrder order = ListOrder.ORDER_NORMAL;

  double? _lastVolume;
  late final RxDouble desktopVolume = RxDouble(Pref.desktopVolume);

  Timer? _statusTimer;

  void _startStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = Timer(
      const Duration(milliseconds: 500),
      _updatePlaybackState,
    );
  }

  void _stopStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  late final volumeDraft = RxDouble(desktopVolume.value);

  Future<void> toggleVolume() async {
    final before = desktopVolume.value;
    final restoring = _lastVolume != null;
    if (await setVolume(_lastVolume ?? 0, clearLastVolme: false)) {
      _lastVolume = restoring ? null : before;
    }
  }

  void previewVolume(double value) {
    volumeDraft.value = roundVolumeRatio(value.clamp(0.0, Pref.maxVolume));
    setVolume(volumeDraft.value);
  }

  Future<bool> setVolume(double volume, {bool clearLastVolme = true}) async {
    volume = roundVolumeRatio(volume.clamp(0.0, Pref.maxVolume));
    final target = player;
    final generation = _playGeneration;
    final account = Accounts.main;
    final revision = ++_volumeRevision;
    try {
      await _readyPlayer.setVolume(volumePercent(volume));
      if (!_ownsControl(target, generation, account) ||
          revision != _volumeRevision) {
        return false;
      }
      desktopVolume.value = volume;
      volumeDraft.value = volume;
      if (clearLastVolme) _lastVolume = null;
      return true;
    } catch (error, stack) {
      if (_ownsControl(target, generation, account) &&
          revision == _volumeRevision) {
        volumeDraft.value = desktopVolume.value;
        _reportControlFailure('音量调整失败，请重试', error, stack);
      }
      return false;
    }
  }

  Future<void> commitVolumeChange(double value) async {
    if (await setVolume(value)) await syncVolume();
  }

  Future<void> setPlayerVolumePercent(double value) async {
    if (!await setVolume(value / 100)) return;
    await _saveVolume(
      SettingBoxKey.playerVolume,
      volumePercent(desktopVolume.value),
    );
  }

  Future<void> _saveVolume(String key, double value) async {
    final target = player;
    final generation = _playGeneration;
    final account = Accounts.main;
    final revision = _volumeRevision;
    try {
      await GStorage.setting.put(key, value);
    } catch (error, stack) {
      if (_ownsControl(target, generation, account) &&
          revision == _volumeRevision) {
        _reportControlFailure('音量已调整，设置保存失败，请重试', error, stack);
      }
    }
  }

  Future<void> syncVolume([_]) async {
    final volume = desktopVolume.value;
    final target = player;
    final generation = _playGeneration;
    final account = Accounts.main;
    final revision = _volumeRevision;
    await _saveVolume(SettingBoxKey.desktopVolume, roundVolumeRatio(volume));
    if (!_ownsControl(target, generation, account) ||
        revision != _volumeRevision) {
      return;
    }
    try {
      final result = await PlPlayerController.instance?.setPlayerVolumePercent(
        volumePercent(volume),
      );
      if (!_ownsControl(target, generation, account) ||
          revision != _volumeRevision) {
        return;
      }
      if (result?.outcome == CommandOutcome.failed) {
        throw result!.failure ?? StateError('视频音量同步失败');
      }
    } catch (error, stack) {
      if (_ownsControl(target, generation, account) &&
          revision == _volumeRevision) {
        _reportControlFailure('音频音量已调整，视频音量同步失败', error, stack);
      }
    }
  }

  @override
  void onInit() {
    super.onInit();
    _ensureAudioLease();
    final args = Get.arguments;
    oid = Int64(args['oid']);
    final id = args['id'];
    this.id = id != null ? Int64(id) : oid;
    subId = (args['subId'] as List<int>?)?.map(Int64.new).toList() ?? [oid];
    itemType = args['itemType'];
    from = args['from'];
    _start = args['start'];
    final int? extraId = args['extraId'];
    if (extraId != null) {
      this.extraId = Int64(extraId);
    }
    if (args['heroTag'] case String heroTag) {
      try {
        _videoDetailController = Get.find<VideoDetailController>(tag: heroTag);
      } catch (_) {}
    }

    animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    reloadPlaylist();

    final String? audioUrl = args['audioUrl'];
    final hasAudioUrl = audioUrl != null;
    if (hasAudioUrl) {
      _querySponsorBlock();
      _playAccount = Accounts.main;
      _onOpenMedia(
        audioUrl,
        generation: ++_playGeneration,
        ua: BrowserUa.pc,
        referer: HttpString.baseUrl,
        volume: _videoDetailController?.volume,
      );
    }
    ConnectivityUtils.isWiFi.then((isWiFi) {
      if (isClosed) return;
      cacheAudioQa = isWiFi ? Pref.defaultAudioQa : Pref.defaultAudioQaCellular;
      if (!hasAudioUrl) {
        _queryPlayUrl();
      }
    });
    videoPlayerServiceHandler
      ?..onPlay = onPlay
      ..onPause = onPause
      ..onSeek = onSeek;

    if (shutdownTimerService.isActive) {
      shutdownTimerService
        ..onPause = onPause
        ..isPlaying = isPlaying;
    }
  }

  bool isPlaying() {
    return player?.state.playing ?? false;
  }

  Future<void> onPlay() => Future<void>.sync(() {
    final target = _readyPlayer;
    return _audioLease?.setPlaying(true) ?? target.play();
  });

  Future<void> onPause() => Future<void>.sync(() {
    final target = _readyPlayer;
    return _audioLease?.setPlaying(false) ?? target.pause();
  });

  Future<void> onSeek(Duration duration) async {
    final target = _readyPlayer;
    final generation = _playGeneration;
    final account = Accounts.main;
    final revision = ++_seekRevision;
    await target.seek(duration);
    if (!_ownsControl(target, generation, account) ||
        revision != _seekRevision) {
      return;
    }
    position.value = duration.inSeconds;
    _updatePlaybackState(position: duration);
  }

  Future<void> _consumePlaybackControl(
    Future<void> Function() operation,
  ) async {
    final target = player;
    final generation = _playGeneration;
    final account = Accounts.main;
    try {
      await operation();
    } catch (error, stack) {
      if (_ownsControl(target, generation, account)) {
        _reportControlFailure('播放操作失败，请重试', error, stack);
      }
    }
  }

  Future<void> playFromUi() => _consumePlaybackControl(onPlay);
  Future<void> pauseFromUi() => _consumePlaybackControl(onPause);

  Future<void> seekFromUi(Duration duration) async {
    final target = player;
    final generation = _playGeneration;
    final account = Accounts.main;
    final operation = onSeek(duration);
    final revision = _seekRevision;
    try {
      await operation;
    } catch (error, stack) {
      if (_ownsControl(target, generation, account) &&
          revision == _seekRevision) {
        position.value = target?.state.position.inSeconds ?? 0;
        _reportControlFailure('进度调整失败，请重试', error, stack);
      }
    }
  }

  void _updateCurrItem(DetailItem item) {
    _interactionAccount = Accounts.main;
    audioItem.value = item;
    hasLike.value = item.stat.hasLike_7;
    coinNum.value = item.stat.hasCoin_8 ? 2 : 0;
    hasFav.value = item.stat.hasFav;
    final handler = videoPlayerServiceHandler;
    if (handler == null || handler.onPlay != onPlay) return;
    try {
      handler.onVideoDetailChange(
        item,
        (subId.firstOrNull ?? oid).toInt(),
        hashCode.toString(),
      );
    } catch (error, stack) {
      logger
          .scoped('audio')
          .w('系统音频信息同步失败', error: error.runtimeType, stackTrace: stack);
    }
  }

  bool _ownsPlaylist(int generation, Account account) =>
      !_audioClosed &&
      !isClosed &&
      generation == _playlistGeneration &&
      identical(account, Accounts.main);

  void _onPlaylistAccountChanged() {
    if (!identical(_playlistAccount, Accounts.main)) reloadPlaylist();
  }

  Future<bool> reloadPlaylist() async {
    if (_audioClosed || isClosed) return false;
    if (!_listeningToPlaylistAccount) {
      Accounts.mainChanges.addListener(_onPlaylistAccountChanged);
      _listeningToPlaylistAccount = true;
    }
    final account = Accounts.main;
    if (!identical(account, _playlistAccount)) {
      playlist = null;
      index = null;
      _prev = _next = null;
    }
    _playlistAccount = account;
    final generation = ++_playlistGeneration;
    _pageOperation = null;
    _prevEmptyPages = _nextEmptyPages = 0;
    _removedPlaylistItems.clear();
    playlistState.value = LoadingState.loading();
    playlistPageState.value = const Success(null);
    playlistRevision.value++;
    final anchorOid = oid;
    final anchorSubIds = List<Int64>.of(subId);
    try {
      final res = await AudioGrpc.audioPlayList(
        id: id,
        oid: anchorOid,
        subId: anchorSubIds,
        itemType: itemType,
        from: from,
        extraId: extraId,
        order: order,
      );
      if (!_ownsPlaylist(generation, account)) return false;
      if (res case Success(:final response)) {
        final keys = <(int, Int64)>{..._removedPlaylistItems};
        final items = response.list
            .where((entry) => keys.add((entry.item.itemType, entry.item.oid)))
            .toList();
        final selected = items.indexWhere(
          (entry) => entry.item.oid == oid && entry.item.itemType == itemType,
        );
        playlist = items;
        index = selected >= 0 ? selected : null;
        _prev = _playlistCursor(
          response.reachStart,
          response.paginationReply.prev,
        );
        _next = _playlistCursor(
          response.reachEnd,
          response.paginationReply.next,
        );
        // 列表可以不含正在播放的资源，不擅自把首项当作当前音频。
        if (selected >= 0 &&
            oid == anchorOid &&
            listEquals(subId, anchorSubIds)) {
          _updateCurrItem(items[selected]);
        }
        playlistState.value = const Success(null);
        playlistRevision.value++;
        return true;
      }
      playlistState.value = res is Error ? res : const Error('播放列表尚未加载完成，请重试');
    } catch (error, stack) {
      if (!_ownsPlaylist(generation, account)) return false;
      logger
          .scoped('audio')
          .w('音频列表加载失败', error: error.runtimeType, stackTrace: stack);
      playlistState.value = Error(
        '播放列表加载失败，请重试',
        cause: error,
        stackTrace: stack,
      );
    }
    return false;
  }

  static String? _playlistCursor(bool reachedEnd, String cursor) =>
      reachedEnd || cursor.isEmpty ? null : cursor;

  Future<bool> _loadPlaylistPage({
    required bool previous,
    bool retry = false,
  }) async {
    if (isClosed ||
        _pageOperation != null ||
        !playlistState.value.isSuccess ||
        !identical(_playlistAccount, Accounts.main) ||
        playlist == null ||
        (!retry && playlistPageState.value is Error)) {
      return false;
    }
    final cursor = previous ? _prev : _next;
    if (cursor == null) return false;
    final generation = _playlistGeneration;
    final account = _playlistAccount!;
    final operation = Object();
    _pageOperation = operation;
    _failedPageIsPrev = previous;
    playlistPageState.value = LoadingState.loading();
    try {
      final res = await AudioGrpc.audioPlayList(
        id: id,
        next: cursor,
        extraId: extraId,
        order: order,
      );
      if (!_ownsPlaylist(generation, account)) return false;
      if (res case Success(:final response)) {
        final keys = <(int, Int64)>{
          ..._removedPlaylistItems,
          for (final entry in playlist!) (entry.item.itemType, entry.item.oid),
        };
        final added = response.list
            .where((entry) => keys.add((entry.item.itemType, entry.item.oid)))
            .toList();
        var nextCursor = _playlistCursor(
          previous ? response.reachStart : response.reachEnd,
          previous
              ? response.paginationReply.prev
              : response.paginationReply.next,
        );
        if (nextCursor == cursor) nextCursor = null;
        if (previous) {
          _prevEmptyPages = added.isEmpty ? _prevEmptyPages + 1 : 0;
          _prev = _prevEmptyPages >= 5 ? null : nextCursor;
          playlist!.insertAll(0, added);
          if (index case final selected?) index = selected + added.length;
        } else {
          _nextEmptyPages = added.isEmpty ? _nextEmptyPages + 1 : 0;
          _next = _nextEmptyPages >= 5 ? null : nextCursor;
          playlist!.addAll(added);
        }
        playlistPageState.value = const Success(null);
        playlistRevision.value++;
        return true;
      }
      playlistPageState.value = res is Error
          ? res
          : const Error('播放列表尚未加载完成，请重试');
    } catch (error, stack) {
      if (!_ownsPlaylist(generation, account)) return false;
      logger
          .scoped('audio')
          .w('音频列表分页失败', error: error.runtimeType, stackTrace: stack);
      playlistPageState.value = Error(
        '播放列表加载失败，请重试',
        cause: error,
        stackTrace: stack,
      );
    } finally {
      if (identical(_pageOperation, operation)) _pageOperation = null;
    }
    return false;
  }

  void removePlaylistItem(DetailItem item) {
    final items = playlist;
    final removedIndex =
        items?.indexWhere((entry) => identical(entry, item)) ?? -1;
    if (removedIndex < 0 || removedIndex == index) return;
    _removedPlaylistItems.add((item.item.itemType, item.item.oid));
    items!.removeAt(removedIndex);
    if (index case final selected? when removedIndex < selected) {
      index = selected - 1;
    }
    playlistRevision.value++;
  }

  @pragma('vm:notify-debugger-on-exception')
  void _querySponsorBlock() {
    if (isUgc && enableSponsorBlock) {
      try {
        final bvid = IdUtils.av2bv(oid.toInt());
        final cid = subId.first.toInt();
        querySponsorBlock(bvid: bvid, cid: cid);
      } catch (_) {}
    }
  }

  bool _ownsPlayback(int generation) =>
      !_audioClosed &&
      !isClosed &&
      generation == _playGeneration &&
      identical(_playAccount, Accounts.main);

  bool _playbackFailed(Object error, StackTrace stack, int generation) {
    if (_ownsPlayback(generation)) {
      logger
          .scoped('audio')
          .w(
            '音频播放失败',
            error: error.runtimeType,
            stackTrace: stack,
          );
      SmartDialog.showToast('音频播放失败，请重试');
    }
    return false;
  }

  Future<bool> _queryPlayUrl() async {
    final generation = ++_playGeneration;
    _pendingPlayGeneration = generation;
    _playAccount = Accounts.main;
    _playbackReady = false;
    _querySponsorBlock();
    try {
      final res = await AudioGrpc.audioPlayUrl(
        itemType: itemType,
        oid: oid,
        subId: List.of(subId),
      );
      if (!_ownsPlayback(generation)) return false;
      if (res case Success(:final response)) {
        final opened = await _onPlay(response, generation);
        return opened && _ownsPlayback(generation);
      }
      res.toast();
      return false;
    } catch (error, stack) {
      return _playbackFailed(error, stack, generation);
    } finally {
      if (_pendingPlayGeneration == generation) {
        _pendingPlayGeneration = null;
      }
    }
  }

  Future<bool> _onPlay(PlayURLResp data, int generation) {
    final PlayInfo? playInfo = data.playerInfo.values.firstOrNull;
    if (playInfo == null) throw const FormatException('响应缺少音频信息');
    http_model.Volume? volume;
    if (playInfo.hasVolume()) {
      final volumeInfo = playInfo.volume;
      volume = http_model.Volume(
        measuredI: volumeInfo.measuredI,
        measuredLra: volumeInfo.measuredLra,
        measuredTp: volumeInfo.measuredTp,
        measuredThreshold: volumeInfo.measuredThreshold,
        targetOffset: volumeInfo.targetOffset,
        targetI: volumeInfo.targetI,
        targetTp: volumeInfo.targetTp,
      );
    }
    final Iterable<String> urls;
    if (playInfo.hasPlayDash()) {
      if (playInfo.playDash.audio.isEmpty) {
        throw const FormatException('响应缺少音频来源');
      }
      final audio = playInfo.playDash.audio.findClosestTarget(
        (e) => e.id <= cacheAudioQa,
        (a, b) => a.id > b.id ? a : b,
      );
      urls = audio.playUrls;
    } else if (playInfo.hasPlayUrl() && playInfo.playUrl.durl.isNotEmpty) {
      urls = playInfo.playUrl.durl.first.playUrls;
    } else {
      throw const FormatException('响应缺少音频来源');
    }
    return _onOpenMedia(
      VideoUtils.getCdnUrl(urls),
      generation: generation,
      volume: volume,
    );
  }

  Future<bool> _onOpenMedia(
    String url, {
    required int generation,
    String ua = Constants.userAgentApp,
    String? referer,
    http_model.Volume? volume,
  }) {
    _pendingPlayGeneration = generation;
    _ensureAudioLease();
    final lease = _audioLease;
    final intentRevision = lease?.intentRevision;
    final previous = _mediaOpening;
    // 原生 open 不能撤销，串行打开才能保证最后一次选曲最终拥有播放器。
    final operation = () async {
      try {
        await previous;
        if (!_ownsPlayback(generation)) return false;
        if (url.trim().isEmpty) throw const FormatException('音频来源为空');
        await _initPlayerIfNeeded();
        if (!_ownsPlayback(generation)) return false;
        await _audioLease?.prepare();
        if (!_ownsPlayback(generation)) return false;
        final currentPlayer = player!
          ..setMediaHeader(
            userAgent: ua,
            // mpv cannot clear referer option
            headers: {'Referer': ?referer},
          );
        await currentPlayer.open(
          Media(url, start: _start, extras: audioFilterExtras(volume)),
          play: _audioLease == null,
        );
        if (!_ownsPlayback(generation)) return false;
        // 打开期间的显式暂停和拔耳机意图优先于本次自动起播。
        await lease?.setPlaying(
          lease.intentRevision == intentRevision ? true : lease.playingIntent,
        );
        if (!_ownsPlayback(generation)) return false;
        position.value = 0;
        _playbackReady = true;
        _start = null;
        return true;
      } catch (error, stack) {
        return _playbackFailed(error, stack, generation);
      } finally {
        if (_pendingPlayGeneration == generation) {
          _pendingPlayGeneration = null;
        }
      }
    }();
    _mediaOpening = operation;
    return operation;
  }

  PlayerStatus _playerStatus = .paused;
  void _updatePlaybackState({Duration? position, String? debugLabel}) {
    final target = player;
    final handler = videoPlayerServiceHandler;
    if (_audioClosed ||
        isClosed ||
        target == null ||
        handler == null ||
        handler.onPlay != onPlay) {
      return;
    }
    try {
      handler.onUpdateState(
        _playerStatus,
        false,
        false,
        position: position ?? target.state.position,
        speed: speed,
        debugLabel: debugLabel,
      );
    } catch (error, stack) {
      logger
          .scoped('audio')
          .w('系统播放状态同步失败', error: error.runtimeType, stackTrace: stack);
    }
  }

  Future<void> _initPlayerIfNeeded() async {
    if (player != null) return;
    final initialization = _playerInitialization ??= _initializePlayer();
    try {
      await initialization;
    } finally {
      if (identical(_playerInitialization, initialization)) {
        _playerInitialization = null;
      }
    }
  }

  Future<void> _initializePlayer() async {
    _ensureAudioLease();
    final initializedPlayer = await _createPlayer(
      PlayerConfiguration(
        options: {
          if (Platform.isAndroid) 'ao': Pref.audioOutput,
          'volume': PlatformUtils.isDesktop
              ? volumePercent(desktopVolume.value).toStringAsFixed(0)
              : Pref.playerVolume.toString(),
          ...Pref.initBuffer(),
        },
      ),
    );
    if (_audioClosed || isClosed) {
      // 交由关闭流程统一销毁，失败必须继续持有音频租约和视频抑制。
      _closingPlayer = initializedPlayer;
      return;
    }
    player = initializedPlayer;
    final stream = initializedPlayer.stream;
    _subscriptions = [
      stream.position.listen((position) {
        if (_audioClosed || isClosed || !identical(player, initializedPlayer)) {
          return;
        }
        if (isDragging) return;
        final seconds = position.inSeconds;
        if (seconds != this.position.value) {
          if (seconds == 0 && _playerStatus.isPlaying) {
            _updatePlaybackState(position: position);
          }
          this.position.value = seconds;
          _videoDetailController?.playedTime = position;
        }
      }),
      stream.duration.listen((duration) {
        if (_audioClosed || isClosed || !identical(player, initializedPlayer)) {
          return;
        }
        this.duration.value = duration.inSeconds;
      }),
      stream.playing.listen((playing) {
        if (_audioClosed || isClosed || !identical(player, initializedPlayer)) {
          return;
        }
        if (playing) {
          animController.forward();
          _playerStatus = .playing;
          _stopStatusTimer();
          _updatePlaybackState();
        } else {
          animController.reverse();
          _playerStatus = .paused;
          _startStatusTimer();
        }
      }),
      stream.buffering.listen((bool buffering) {
        if (_audioClosed || isClosed || !identical(player, initializedPlayer)) {
          return;
        }
        if (!_playerStatus.isCompleted) {
          _stopStatusTimer();
          _updatePlaybackState();
        }
      }),
      stream.completed.listen((completed) {
        if (_audioClosed || isClosed || !identical(player, initializedPlayer)) {
          return;
        }
        _videoDetailController?.playedTime = player!.state.duration;
        if (completed) {
          _playerStatus = .completed;
          _startStatusTimer();
          if (shutdownTimerService.isWaiting) {
            shutdownTimerService.handleWaiting();
          } else {
            switch (playMode.value) {
              case PlayRepeat.pause:
                break;
              case PlayRepeat.listOrder:
                playNext(nextPart: true);
                break;
              case PlayRepeat.singleCycle:
                playFromUi();
                break;
              case PlayRepeat.listCycle:
                if (!playNext(nextPart: true)) {
                  if (index != null && index != 0 && playlist != null) {
                    playIndex(0);
                  } else {
                    playFromUi();
                  }
                }
                break;
              case PlayRepeat.autoPlayRelated:
                break;
            }
          }
        }
      }),
    ];
  }

  bool _interactionBusy = false;
  Account? _interactionAccount;

  bool _canInteract() {
    final item = audioItem.value;
    if (item == null ||
        item.item.oid != oid ||
        item.item.itemType != itemType ||
        (_interactionAccount != null &&
            !identical(_interactionAccount, Accounts.main))) {
      SmartDialog.showToast('曲目信息待更新，请刷新播放列表后重试');
      return false;
    }
    return true;
  }

  bool _ownsInteraction(
    Account account,
    DetailItem? item,
    Int64 target,
    int type,
    List<Int64> parts,
  ) =>
      !_audioClosed &&
      !isClosed &&
      identical(account, Accounts.main) &&
      identical(item, audioItem.value) &&
      oid == target &&
      itemType == type &&
      listEquals(subId, parts);

  Future<void> _runInteraction(
    Future<void> Function(Account account, bool Function() current) action,
  ) async {
    if (_interactionBusy || _audioClosed || isClosed) return;
    final account = Accounts.main;
    if (!account.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    if (!_canInteract()) return;
    final item = audioItem.value;
    final target = oid;
    final type = itemType;
    final parts = List<Int64>.of(subId);
    bool current() => _ownsInteraction(account, item, target, type, parts);
    _interactionBusy = true;
    try {
      await action(account, current);
    } catch (error, stack) {
      logger
          .scoped('audio')
          .w('音频互动未完成', error: error.runtimeType, stackTrace: stack);
      if (current()) const UnknownResult().toast();
    } finally {
      _interactionBusy = false;
    }
  }

  @override
  Future<void> Function(int, bool) get payCoinCallback {
    final account = Accounts.main;
    final item = audioItem.value;
    final target = oid;
    final type = itemType;
    final parts = List<Int64>.of(subId);
    return (coin, withLike) async {
      if (!_ownsInteraction(account, item, target, type, parts)) {
        if (!isClosed) SmartDialog.showToast('曲目或账号已更新，请重新打开投币面板');
        return;
      }
      await onPayCoin(coin, withLike);
    };
  }

  @override
  Future<void> actionLikeVideo() => _runInteraction((account, current) async {
    final newVal = !hasLike.value;
    final res = await AudioGrpc.audioThumbUp(
      account: account,
      oid: oid,
      subId: List.of(subId),
      itemType: itemType,
      type: newVal
          ? ThumbUpReq_ThumbType.LIKE
          : ThumbUpReq_ThumbType.CANCEL_LIKE,
    );
    if (!current()) return;
    if (res case Success(:final response)) {
      hasLike.value = newVal;
      final stat = audioItem.value?.stat;
      if (stat != null) {
        stat
          ..hasLike_7 = newVal
          ..like += newVal ? 1 : -1;
        audioItem.refresh();
      }
      SmartDialog.showToast(response.message);
    } else {
      res.toast();
    }
  });

  @override
  Future<void> actionTriple() => _runInteraction((account, current) async {
    final previousCoins = coinNum.value;
    final res = await AudioGrpc.audioTripleLike(
      account: account,
      oid: oid,
      subId: List.of(subId),
      itemType: itemType,
    );
    if (res case Success(:final response)) {
      final addedCoins = response.coinOk && previousCoins == 0 ? 2 : 0;
      if (addedCoins > 0 && identical(account, Accounts.main)) {
        GlobalData().afterCoin(addedCoins.toInt());
      }
      if (!current()) return;
      // 三连允许部分成功，只应用各步骤已确认的状态。
      final stat = audioItem.value?.stat;
      if (response.thumbOk && !hasLike.value) {
        hasLike.value = true;
        stat
          ?..hasLike_7 = true
          ..like += 1;
      }
      if (addedCoins > 0) {
        coinNum.value += addedCoins;
        stat
          ?..hasCoin_8 = true
          ..coin += addedCoins.toInt();
      }
      if (response.favOk && !hasFav.value) {
        hasFav.value = true;
        stat
          ?..hasFav = true
          ..favourite += 1;
      }
      audioItem.refresh();
      SmartDialog.showToast(
        response.thumbOk && response.coinOk && response.favOk
            ? '三连成功'
            : '部分操作未完成，请核对点赞、投币和收藏状态',
      );
    } else if (current()) {
      res.toast();
    }
  });

  @override
  int get copyright => audioItem.value?.arc.copyright ?? 1;

  @override
  Future<void> onPayCoin(int coin, bool coinWithLike) =>
      _runInteraction((account, current) async {
        if (coin <= 0 || coinNum.value + coin > (copyright == 2 ? 1 : 2)) {
          SmartDialog.showToast('达到投币上限啦~');
          return;
        }
        final res = await AudioGrpc.audioCoinAdd(
          account: account,
          oid: oid,
          subId: List.of(subId),
          itemType: itemType,
          num: coin,
          thumbUp: coinWithLike,
        );
        if (res.isSuccess && identical(account, Accounts.main)) {
          GlobalData().afterCoin(coin);
        }
        if (!current()) return;
        if (res.isSuccess) {
          final updateLike = !hasLike.value && coinWithLike;
          if (updateLike) hasLike.value = true;
          coinNum.value += coin;
          final stat = audioItem.value?.stat;
          if (stat != null) {
            stat
              ..hasCoin_8 = true
              ..coin += coin;
            if (updateLike) {
              stat
                ..hasLike_7 = true
                ..like += 1;
            }
            audioItem.refresh();
          }
          SmartDialog.showToast('投币成功');
        } else {
          res.toast();
        }
      });

  (Account, (Object, int))? _favPanelTarget;

  @override
  Future<void> actionFavVideo({bool isQuick = false}) async {
    if (!isQuick && _favPanelTarget != (Accounts.main, getFavRidType)) {
      SmartDialog.showToast('曲目或账号已更新，请重新打开收藏面板');
      return;
    }
    await _runInteraction(
      (account, current) => super.actionFavVideo(isQuick: isQuick),
    );
  }

  @override
  void showFavBottomSheet(BuildContext context, {bool isLongPress = false}) {
    if (!_canInteract()) return;
    _favPanelTarget = (Accounts.main, getFavRidType);
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    if (enableQuickFav) {
      if (!isLongPress) {
        actionFavVideo(isQuick: true);
      } else {
        PageUtils.showFavBottomSheet(context: context, ctr: this);
      }
    } else if (!isLongPress) {
      PageUtils.showFavBottomSheet(context: context, ctr: this);
    }
  }

  void showReply() {
    MainReplyPage.toMainReplyPage(
      oid: oid.toInt(),
      replyType: isUgc ? 1 : 14,
    );
  }

  void actionShareVideo(BuildContext context) {
    final item = audioItem.value?.deepCopy();
    final target = item?.item.oid ?? oid;
    final ugc = (item?.item.itemType ?? itemType) == 1;
    final account = Accounts.main;
    bool current() =>
        context.mounted && !isClosed && identical(account, Accounts.main);
    final audioUrl = ugc
        ? '${HttpString.baseUrl}/video/${IdUtils.av2bv(target.toInt())}'
        : '${HttpString.baseUrl}/audio/au$target';
    showDialog(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          DialogOption(
            child: const Text('复制链接', style: TextStyle(fontSize: 14)),
            onPressed: () {
              if (!current()) return;
              Navigator.of(dialogContext).pop();
              Utils.copyText(audioUrl);
            },
          ),
          DialogOption(
            child: const Text('其它app打开', style: TextStyle(fontSize: 14)),
            onPressed: () {
              if (!current()) return;
              Navigator.of(dialogContext).pop();
              PiliAndroidHelper.openUrl(audioUrl);
            },
          ),
          if (PlatformUtils.isMobile)
            DialogOption(
              child: const Text('分享视频', style: TextStyle(fontSize: 14)),
              onPressed: () {
                if (!current()) return;
                Navigator.of(dialogContext).pop();
                if (item case DetailItem(
                  :final arc,
                  :final owner,
                )) {
                  ShareUtils.shareText(
                    '${arc.title} '
                    'UP主: ${owner.name}'
                    ' - $audioUrl',
                  );
                }
              },
            ),
          if (account.isLogin)
            DialogOption(
              child: const Text('分享至动态', style: TextStyle(fontSize: 14)),
              onPressed: () {
                if (!current()) return;
                Navigator.of(dialogContext).pop();
                if (item case DetailItem(
                  :final arc,
                  :final owner,
                )) {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (context) => RepostPanel(
                      rid: target.toInt(),
                      dynType: ugc ? 8 : 256,
                      pic: arc.cover,
                      title: arc.title,
                      uname: owner.name,
                    ),
                  );
                }
              },
            ),
          if (ugc && account.isLogin)
            DialogOption(
              child: const Text('分享至消息', style: TextStyle(fontSize: 14)),
              onPressed: () async {
                if (!current()) return;
                Navigator.of(dialogContext).pop();
                if (item case DetailItem(
                  :final arc,
                  :final owner,
                )) {
                  try {
                    await PageUtils.pmShare(
                      context,
                      content: {
                        "id": target.toString(),
                        "title": arc.title,
                        "headline": arc.title,
                        "source": 5,
                        "thumb": arc.cover,
                        "author": owner.name,
                        "author_id": owner.mid.toString(),
                      },
                    );
                  } catch (error, stack) {
                    logger
                        .scoped('audio')
                        .w(
                          '音频消息分享失败',
                          error: error.runtimeType,
                          stackTrace: stack,
                        );
                    if (current()) SmartDialog.showToast('分享失败，请重试');
                  }
                }
              },
            ),
        ],
      ),
    );
  }

  Future<void> playOrPause() => _consumePlaybackControl(() {
    if (_audioLease case final lease?) {
      return lease.playingIntent ? onPause() : onPlay();
    }
    return _readyPlayer.playOrPause();
  });

  bool playPrev() {
    if (index != null && playlist != null && player != null) {
      final prev = index! - 1;
      if (prev >= 0) {
        playIndex(prev);
        return true;
      }
    }
    return false;
  }

  bool playNext({bool nextPart = false}) {
    if (nextPart) {
      if (audioItem.value case DetailItem(:final parts)) {
        if (parts.length > 1) {
          final subId = this.subId.firstOrNull;
          final nextIndex = parts.indexWhere((e) => e.subId == subId) + 1;
          if (nextIndex != 0 && nextIndex < parts.length) {
            final nextPart = parts[nextIndex];
            _start = null;
            oid = nextPart.oid;
            this.subId = [nextPart.subId];
            final operation = _queryPlayUrl();
            final generation = _playGeneration;
            operation.then((res) {
              if (res && _ownsPlayback(generation)) {
                _videoDetailController = null;
              }
            });
            return true;
          }
        }
      }
    }
    if (index != null && playlist != null && player != null) {
      final next = index! + 1;
      if (next < playlist!.length) {
        if (next == playlist!.length - 1 && _next != null) {
          loadNext();
        }
        playIndex(next);
        return true;
      }
    }
    return false;
  }

  Future<void> selectPlaylistItem(DetailItem item, {List<Int64>? subId}) {
    // 行点击归属实际快照，前插分页和重排后不能沿用旧位置。
    final selected =
        playlist?.indexWhere((entry) => identical(entry, item)) ?? -1;
    if (selected < 0) return Future.value();
    return playIndex(selected, subId: subId);
  }

  Future<void> playIndex(int index, {List<Int64>? subId}) async {
    final audioItem = playlist![index];
    final item = audioItem.item;
    final targetSubIds =
        subId ??
        (item.subId.isNotEmpty
            ? item.subId
            : [if (audioItem.parts.firstOrNull case final part?) part.subId]);
    if (index == this.index &&
        item.oid == oid &&
        item.itemType == itemType &&
        listEquals(targetSubIds, this.subId) &&
        _ownsPlayback(_playGeneration) &&
        (_playbackReady || _pendingPlayGeneration == _playGeneration)) {
      return;
    }
    _start = null;
    this.index = index;
    oid = item.oid;
    this.subId = List.of(targetSubIds);
    itemType = item.itemType;
    final operation = _queryPlayUrl();
    final generation = _playGeneration;
    if (await operation && _ownsPlayback(generation)) {
      _videoDetailController = null;
      _updateCurrItem(audioItem);
    }
  }

  @override
  (Object, int) get getFavRidType => (oid, isUgc ? 2 : 12);

  @override
  void updateFavCount(int count) {
    try {
      audioItem.value!.stat
        ..hasFav = count > 0
        ..favourite += count;
      audioItem.refresh();
    } catch (_) {}
  }

  Future<bool> loadPrev() => _loadPlaylistPage(previous: true, retry: true);

  Future<bool> loadNext() => _loadPlaylistPage(previous: false);

  Future<bool> retryPlaylistPage() =>
      _loadPlaylistPage(previous: _failedPageIsPrev, retry: true);

  Future<bool> onChangeOrder(ListOrder value) {
    if (order == value &&
        playlistState.value is! Error &&
        identical(_playlistAccount, Accounts.main)) {
      return Future.value(false);
    }
    order = value;
    return reloadPlaylist();
  }

  @override
  BlockConfigMixin get blockConfig => this;

  @override
  Future<void> applyBlockMute(bool muted) async {
    player?.setProperty('mute', muted ? 'yes' : 'no');
  }

  @override
  int get currPosInMilliseconds => player?.state.position.inMilliseconds ?? 0;

  @override
  int? get timeLength => player?.state.duration.inMilliseconds ?? 0;

  @override
  Future<void>? seekTo(Duration duration, {required bool isSeek}) =>
      onSeek(duration);

  @override
  bool get autoPlay => true;

  @override
  bool get preInitPlayer => true;

  void _releaseAudioResource(FutureOr<void> Function() release) {
    unawaited(
      Future<void>.sync(release).catchError((Object error, StackTrace stack) {
        logger
            .scoped('audio')
            .w('音频资源释放失败', error: error.runtimeType, stackTrace: stack);
      }),
    );
  }

  @override
  void onClose() {
    _audioClosed = true;
    _playlistGeneration++;
    if (_listeningToPlaylistAccount) {
      Accounts.mainChanges.removeListener(_onPlaylistAccountChanged);
      _listeningToPlaylistAccount = false;
    }
    _playGeneration++;
    _stopStatusTimer();
    final ownsTimerPause = shutdownTimerService.onPause == onPause;
    final ownsTimerPlaying = shutdownTimerService.isPlaying == isPlaying;
    if (ownsTimerPause) shutdownTimerService.onPause = null;
    if (ownsTimerPlaying) shutdownTimerService.isPlaying = null;
    if ((ownsTimerPause || ownsTimerPlaying) &&
        shutdownTimerService.onPause == null &&
        shutdownTimerService.isPlaying == null) {
      shutdownTimerService.reset();
    }
    final handler = videoPlayerServiceHandler;
    if (handler != null) {
      final ownsPlay = handler.onPlay == onPlay;
      final ownsPause = handler.onPause == onPause;
      final ownsSeek = handler.onSeek == onSeek;
      if (ownsPlay) handler.onPlay = null;
      if (ownsPause) handler.onPause = null;
      if (ownsSeek) handler.onSeek = null;
      _releaseAudioResource(() {
        handler.onVideoDetailDispose(hashCode.toString());
        if (ownsPlay || ownsPause || ownsSeek) handler.clearIfNeeded();
      });
    }
    for (final subscription in _subscriptions ?? <StreamSubscription>[]) {
      _releaseAudioResource(subscription.cancel);
    }
    _subscriptions = null;
    final target = player;
    player = null;
    final lease = _audioLease;
    _audioLease = null;
    _releaseAudioResource(() {
      Future<void> release() async {
        // 等初始化和不可撤销的 open 真正退出后再销毁，最后交还视频抑制。
        try {
          await _playerInitialization;
        } catch (_) {
          // 创建失败已由播放入口交付，没有可继续销毁的资源。
        }
        await _mediaOpening;
        final releasing = target ?? _closingPlayer;
        if (releasing != null) await releasing.dispose();
        _closingPlayer = null;
      }

      // 立即登记关闭，后续音频接管必须等待上述真实释放屏障。
      return lease?.close(release) ?? release();
    });
    animController.dispose();
    super.onClose();
  }
}

extension on DashItem {
  Iterable<String> get playUrls sync* {
    yield baseUrl;
    yield* backupUrl;
  }
}

extension on ResponseUrl {
  Iterable<String> get playUrls sync* {
    yield url;
    yield* backupUrl;
  }
}

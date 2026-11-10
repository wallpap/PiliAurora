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
import 'package:pili_aurora/services/service_locator.dart';
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
  late final bool isUgc = itemType == 1;

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
  @override
  Player? player;
  late int cacheAudioQa;

  late bool isDragging = false;
  final RxInt position = RxInt(0);
  final RxInt duration = RxInt(0);

  late final AnimationController animController;

  List<StreamSubscription>? _subscriptions;

  int? index;
  List<DetailItem>? playlist;

  late double speed = 1.0;

  void setSpeed(double value) {
    if (player case final player?) {
      speed = value;
      player.setRate(value);
      _updatePlaybackState();
    }
  }

  late final Rx<PlayRepeat> playMode = Pref.audioPlayMode.obs;

  @override
  late final isLogin = Accounts.main.isLogin;

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

  void toggleVolume() {
    if (_lastVolume == null) {
      _lastVolume = desktopVolume.value;
      setVolume(0, clearLastVolme: false);
    } else {
      setVolume(_lastVolume!);
    }
  }

  void setVolume(double volume, {bool clearLastVolme = true}) {
    if (clearLastVolme) {
      _lastVolume = null;
    }
    volume = roundVolumeRatio(volume.clamp(0.0, Pref.maxVolume));
    desktopVolume.value = volume;
    player?.setVolume(volumePercent(volume));
  }

  void syncVolume([_]) {
    final volume = desktopVolume.value;
    PlPlayerController.instance?.setPlayerVolumePercent(
      volumePercent(volume),
    );
    GStorage.setting.put(SettingBoxKey.desktopVolume, roundVolumeRatio(volume));
  }

  @override
  void onInit() {
    super.onInit();
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

  Future<void>? onPlay() {
    return player?.play();
  }

  Future<void>? onPause() {
    return player?.pause();
  }

  Future<void>? onSeek(Duration duration) {
    _updatePlaybackState(position: duration);
    return player?.seek(duration);
  }

  void _updateCurrItem(DetailItem item) {
    audioItem.value = item;
    hasLike.value = item.stat.hasLike_7;
    coinNum.value = item.stat.hasCoin_8 ? 2 : 0;
    hasFav.value = item.stat.hasFav;
    videoPlayerServiceHandler?.onVideoDetailChange(
      item,
      (subId.firstOrNull ?? oid).toInt(),
      hashCode.toString(),
    );
  }

  bool _ownsPlaylist(int generation, Account account) =>
      !isClosed &&
      generation == _playlistGeneration &&
      identical(account, Accounts.main);

  void _onPlaylistAccountChanged() {
    if (!identical(_playlistAccount, Accounts.main)) reloadPlaylist();
  }

  Future<bool> reloadPlaylist() async {
    if (isClosed) return false;
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
    final previous = _mediaOpening;
    // 原生 open 不能撤销，串行打开才能保证最后一次选曲最终拥有播放器。
    final operation = () async {
      try {
        await previous;
        if (!_ownsPlayback(generation)) return false;
        if (url.trim().isEmpty) throw const FormatException('音频来源为空');
        await _initPlayerIfNeeded();
        if (!_ownsPlayback(generation)) return false;
        final currentPlayer = player!
          ..setMediaHeader(
            userAgent: ua,
            // mpv cannot clear referer option
            headers: {'Referer': ?referer},
          );
        await currentPlayer.open(
          Media(url, start: _start, extras: audioFilterExtras(volume)),
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
    videoPlayerServiceHandler?.onUpdateState(
      _playerStatus,
      false,
      false,
      position: position ?? player!.state.position,
      speed: speed,
      debugLabel: debugLabel,
    );
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
    if (isClosed) {
      await initializedPlayer.dispose();
      return;
    }
    player = initializedPlayer;
    final stream = initializedPlayer.stream;
    _subscriptions = [
      stream.position.listen((position) {
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
        this.duration.value = duration.inSeconds;
      }),
      stream.playing.listen((playing) {
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
        if (!_playerStatus.isCompleted) {
          _stopStatusTimer();
          _updatePlaybackState();
        }
      }),
      stream.completed.listen((completed) {
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
                onPlay();
                break;
              case PlayRepeat.listCycle:
                if (!playNext(nextPart: true)) {
                  if (index != null && index != 0 && playlist != null) {
                    playIndex(0);
                  } else {
                    onPlay();
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

  @override
  Future<void> actionLikeVideo() async {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final newVal = !hasLike.value;
    final res = await AudioGrpc.audioThumbUp(
      oid: oid,
      subId: subId,
      itemType: itemType,
      type: newVal
          ? ThumbUpReq_ThumbType.LIKE
          : ThumbUpReq_ThumbType.CANCEL_LIKE,
    );
    if (res case Success(:final response)) {
      hasLike.value = newVal;
      try {
        audioItem.value!.stat
          ..hasLike_7 = newVal
          ..like += newVal ? 1 : -1;
        audioItem.refresh();
      } catch (_) {}
      SmartDialog.showToast(response.message);
    } else {
      res.toast();
    }
  }

  @override
  Future<void> actionTriple() async {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final res = await AudioGrpc.audioTripleLike(
      oid: oid,
      subId: subId,
      itemType: itemType,
    );
    if (res case Success(:final response)) {
      hasLike.value = true;
      if (response.coinOk && !hasCoin) {
        coinNum.value = 2;
        GlobalData().afterCoin(2);
        try {
          audioItem.value!.stat
            ..hasCoin_8 = true
            ..coin += 2;
          audioItem.refresh();
        } catch (_) {}
      }
      hasFav.value = true;
      if (!hasCoin) {
        SmartDialog.showToast('投币失败');
      } else {
        SmartDialog.showToast('三连成功');
      }
    } else {
      res.toast();
    }
  }

  @override
  int get copyright => audioItem.value?.arc.copyright ?? 1;

  @override
  Future<void> onPayCoin(int coin, bool coinWithLike) async {
    final res = await AudioGrpc.audioCoinAdd(
      oid: oid,
      subId: subId,
      itemType: itemType,
      num: coin,
      thumbUp: coinWithLike,
    );
    if (res.isSuccess) {
      final updateLike = !hasLike.value && coinWithLike;
      if (updateLike) {
        hasLike.value = true;
      }
      coinNum.value += coin;
      try {
        final stat = audioItem.value!.stat
          ..hasCoin_8 = true
          ..coin += coin;
        if (updateLike) {
          stat
            ..hasLike_7 = true
            ..like += 1;
        }
        audioItem.refresh();
      } catch (_) {}
      GlobalData().afterCoin(coin);
    } else {
      res.toast();
    }
  }

  @override
  void showFavBottomSheet(BuildContext context, {bool isLongPress = false}) {
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
    final audioUrl = isUgc
        ? '${HttpString.baseUrl}/video/${IdUtils.av2bv(oid.toInt())}'
        : '${HttpString.baseUrl}/audio/au$oid';
    showDialog(
      context: context,
      builder: (_) => SimpleDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          DialogOption(
            child: const Text('复制链接', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              Utils.copyText(audioUrl);
            },
          ),
          DialogOption(
            child: const Text('其它app打开', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              PiliAndroidHelper.openUrl(audioUrl);
            },
          ),
          if (PlatformUtils.isMobile)
            DialogOption(
              child: const Text('分享视频', style: TextStyle(fontSize: 14)),
              onPressed: () {
                Get.back();
                if (audioItem.value case DetailItem(
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
          if (isLogin)
            DialogOption(
              child: const Text('分享至动态', style: TextStyle(fontSize: 14)),
              onPressed: () {
                Get.back();
                if (audioItem.value case DetailItem(
                  :final arc,
                  :final owner,
                )) {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (context) => RepostPanel(
                      rid: oid.toInt(),
                      dynType: isUgc ? 8 : 256,
                      pic: arc.cover,
                      title: arc.title,
                      uname: owner.name,
                    ),
                  );
                }
              },
            ),
          if (isUgc && isLogin)
            DialogOption(
              child: const Text('分享至消息', style: TextStyle(fontSize: 14)),
              onPressed: () {
                Get.back();
                if (audioItem.value case DetailItem(
                  :final arc,
                  :final owner,
                )) {
                  try {
                    PageUtils.pmShare(
                      context,
                      content: {
                        "id": oid.toString(),
                        "title": arc.title,
                        "headline": arc.title,
                        "source": 5,
                        "thumb": arc.cover,
                        "author": owner.name,
                        "author_id": owner.mid.toString(),
                      },
                    );
                  } catch (e) {
                    SmartDialog.showToast(e.toString());
                  }
                }
              },
            ),
        ],
      ),
    );
  }

  Future<void>? playOrPause() {
    return player?.playOrPause();
  }

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
        (item.subId.isNotEmpty ? item.subId : [audioItem.parts.first.subId]);
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

  @override
  void onClose() {
    _playlistGeneration++;
    if (_listeningToPlaylistAccount) {
      Accounts.mainChanges.removeListener(_onPlaylistAccountChanged);
      _listeningToPlaylistAccount = false;
    }
    _playGeneration++;
    _stopStatusTimer();
    shutdownTimerService
      ..onPause = null
      ..isPlaying = null
      ..reset();
    videoPlayerServiceHandler
      ?..onPlay = null
      ..onPause = null
      ..onSeek = null
      ..onVideoDetailDispose(hashCode.toString())
      ..clearIfNeeded();
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
    player?.dispose();
    player = null;
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

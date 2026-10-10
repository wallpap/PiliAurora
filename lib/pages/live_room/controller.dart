import 'dart:async' show Completer, Timer, StreamSubscription, unawaited;
import 'dart:convert' show jsonDecode;
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:pili_aurora/common/widgets/dialog/report.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart'
    show CachedImageProvider;
import 'package:pili_aurora/common/widgets/flutter/text_field/controller.dart';
import 'package:pili_aurora/http/live.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/super_chat_type.dart';
import 'package:pili_aurora/models/common/video/live_quality.dart';
import 'package:pili_aurora/models/model_owner.dart';
import 'package:pili_aurora/models/remote/live/live_danmaku/danmaku_msg.dart';
import 'package:pili_aurora/models/remote/live/live_danmaku/live_emote.dart';
import 'package:pili_aurora/models/remote/live/live_dm_info/data.dart';
import 'package:pili_aurora/models/remote/live/live_medal_wall/uinfo_medal.dart';
import 'package:pili_aurora/models/remote/live/live_room_info_h5/data.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/codec.dart';
import 'package:pili_aurora/models/remote/live/live_room_play_info/stream.dart';
import 'package:pili_aurora/models/remote/live/live_superchat/item.dart';
import 'package:pili_aurora/pages/common/publish/publish_route.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/live_room/chat_buffer.dart';
import 'package:pili_aurora/pages/live_room/send_danmaku/view.dart';
import 'package:pili_aurora/pages/video/widgets/header_control.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/utils/danmaku_options.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/services/live_stream/live.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/android/bindings.g.dart';
import 'package:pili_aurora/utils/connectivity_utils.dart';
import 'package:pili_aurora/utils/danmaku_utils.dart';
import 'package:pili_aurora/utils/duration_utils.dart';
import 'package:pili_aurora/utils/extension/iterable_ext.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/utils/num_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:pili_aurora/utils/video_utils.dart';
import 'package:pili_aurora/utils/rate_limiter.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class LiveRoomController extends GetxController {
  LiveRoomController(this.heroTag);
  final String heroTag;

  int roomId = Get.arguments;
  int? ruid;
  DanmakuController<DanmakuExtra>? danmakuController;
  final plPlayerController = PlPlayerController.getInstance(
    isLive: true,
  );

  final isLoaded = false.obs;
  final roomInfoH5 = Rxn<RoomInfoH5Data>();

  final liveTime = Rxn<int>();
  Timer? liveTimeTimer;

  void startLiveTimer() {
    if (liveTime.value != null) {
      liveTimeTimer ??= Timer.periodic(
        const Duration(minutes: 5),
        (_) => liveTime.refresh(),
      );
    }
  }

  void cancelLiveTimer() {
    liveTimeTimer?.cancel();
    liveTimeTimer = null;
  }

  Widget get timeWidget => Obx(() {
    final liveTime = this.liveTime.value;
    String text = '';
    if (liveTime != null) {
      final duration = DurationUtils.formatDurationBetween(
        liveTime * 1000,
        DateTime.now().millisecondsSinceEpoch,
      );
      text += duration.isEmpty ? '刚刚开播' : '开播$duration';
    }
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        color: Colors.white,
      ),
    );
  });

  // dm
  LiveDmInfoData? dmInfo;
  List<RichTextItem>? savedDanmaku;
  final chatBuffer = LiveChatBuffer<dynamic>();
  final messages = Rx<List<LiveChatMessage<dynamic>>>(const []);
  final unreadMessages = (0, 0).obs;
  final historyTruncated = false.obs;
  int _publishedMessageRevision = 0;
  Timer? _messageRefreshTimer;
  bool get shouldRefresh => _publishedMessageRevision != chatBuffer.revision;
  late final fsSC = Rxn<SuperChatItem>();
  late final RxList<SuperChatItem> superChatMsg = <SuperChatItem>[].obs;
  final disableAutoScroll = false.obs;
  bool _autoScroll = true;
  bool get autoScroll => _autoScroll;
  set autoScroll(bool value) {
    _autoScroll = value;
    if (!value) chatBuffer.pause();
  }

  bool get _followingLatest => autoScroll && !disableAutoScroll.value;
  LiveMessageStream? _msgStream;

  List<String> _keywordList = const [];
  Set<int> _shieldUids = const {};

  late final ScrollController scrollController;
  late final RxInt pageIndex = 0.obs;
  PageController? pageController;

  int? currentQn = PlatformUtils.isMobile ? null : Pref.liveQuality;
  final currentQnDesc = ''.obs;
  final RxBool isPortrait = false.obs;
  late List<({int code, String desc})> acceptQnList = [];

  late final bool isLogin;
  late final int mid;

  String? videoUrl;
  bool? isPlaying;
  late bool isFullScreen = false;

  final superChatType = Pref.superChatType;
  late final showSuperChat = superChatType != SuperChatType.disable;

  final headerKey = GlobalKey<TimeBatteryMixin>();

  final RxString title = ''.obs;

  final RxnString onlineCount = RxnString();

  final RxnString watchedShow = RxnString();
  Widget get watchedWidget => Obx(() {
    if (watchedShow.value case final watchedShow?) {
      return Text(
        watchedShow,
        style: const TextStyle(
          fontSize: 12,
          color: Colors.white,
        ),
      );
    }
    return const SizedBox.shrink();
  });

  void _publishMessages() {
    if (shouldRefresh) {
      messages.value = chatBuffer.history;
      _publishedMessageRevision = chatBuffer.revision;
    }
    unreadMessages.value = (chatBuffer.pendingCount, chatBuffer.droppedPending);
    historyTruncated.value = chatBuffer.historyTruncated;
  }

  void _scheduleMessageRefresh() {
    if (_messageRefreshTimer != null) return;
    _messageRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      _messageRefreshTimer = null;
      _publishMessages();
    });
  }

  void _flushMessageRefresh() {
    _messageRefreshTimer?.cancel();
    _messageRefreshTimer = null;
    _publishMessages();
  }

  StreamSubscription? _sizeSub;

  void _onSizeChanged((int, int) value) {
    final isVertical = value.$2 > value.$1;
    isPortrait.value = isVertical;
    plPlayerController.isVertical = isVertical;
  }

  void _startSizeSub() {
    if (isPortrait.value) return;
    _stopSizeSub();
    _sizeSub = plPlayerController.videoPlayerController?.stream.size.listen(
      _onSizeChanged,
    );
  }

  void _stopSizeSub() {
    _sizeSub?.cancel();
    _sizeSub = null;
  }

  @override
  void onInit() {
    super.onInit();
    scrollController = ScrollController()..addListener(listener);
    final account = Accounts.main;
    isLogin = account.isLogin;
    mid = account.mid;
    queryLiveUrl(autoFullScreenFlag: true);
    queryLiveInfoH5();
    if (Accounts.heartbeat.isLogin && !Pref.historyPause) {
      VideoHttp.roomEntryAction(roomId: roomId);
    }
    if (showSuperChat) {
      pageController = PageController();
    }
  }

  Future<void>? playerInit({
    bool autoplay = true,
    bool autoFullScreenFlag = false,
  }) {
    if (videoUrl == null) {
      return null;
    }
    return plPlayerController.setDataSource(
      NetworkSource(videoSource: videoUrl!, audioSource: null),
      isLive: true,
      autoplay: autoplay,
      isVertical: isPortrait.value,
      autoFullScreenFlag: autoFullScreenFlag,
    );
  }

  Future<void> queryLiveUrl({bool autoFullScreenFlag = false}) async {
    currentQn ??= await ConnectivityUtils.isWiFi
        ? Pref.liveQuality
        : Pref.liveQualityCellular;
    final res = await LiveHttp.liveRoomInfo(
      roomId: roomId,
      qn: currentQn,
      onlyAudio: plPlayerController.onlyPlayAudio.value,
    );
    if (res case Success(:final response)) {
      if (response.liveStatus != 1) {
        _showDialog('当前直播间未开播');
        return;
      }
      final playurl = response.playurlInfo?.playurl;
      if (playurl == null) {
        _showDialog('无法获取播放地址');
        return;
      }
      ruid = response.uid;
      if (response.roomId case final roomId?) {
        this.roomId = roomId;
      }
      liveTime.value = response.liveTime;
      startLiveTimer();
      isPortrait.value = response.isPortrait ?? false;
      stream = playurl.stream;
      _initStreamIndex();
      await Future.wait([
        ?initLiveUrl(
          streamIndex: streamIndex,
          formatIndex: formatIndex,
          codecIndex: codecIndex,
          liveUrlIndex: liveUrlIndex,
        ),
        if (!isLoaded.value && Accounts.heartbeat.isLogin) _fetchBlockRules(),
      ]);
      isLoaded.value = true;
    } else {
      _showDialog(res.toString());
    }
  }

  late List<Stream> stream;
  int streamIndex = 0;
  int formatIndex = 0;
  int codecIndex = 0;
  int liveUrlIndex = 0;

  void _initStreamIndex() {
    final pref = Pref.liveStream;
    if (pref != null) {
      try {
        final String protocolName = pref[0];
        final String formatName = pref[1];
        final String codecName = pref[2];
        for (var (i, s) in stream.indexed) {
          if (s.protocolName == protocolName) {
            streamIndex = i;
            for (var (j, f) in s.format.indexed) {
              if (f.formatName == formatName) {
                formatIndex = j;
                for (var (k, c) in f.codec.indexed) {
                  if (c.codecName == codecName) {
                    codecIndex = k;
                    return;
                  }
                }
              }
            }
          }
        }
      } catch (_) {}
    }
  }

  Future<void>? initLiveUrl({
    int streamIndex = 0,
    int formatIndex = 0,
    int codecIndex = 0,
    int liveUrlIndex = 0,
  }) {
    this.streamIndex = streamIndex;
    this.formatIndex = formatIndex;
    this.codecIndex = codecIndex;
    this.liveUrlIndex = liveUrlIndex;

    final CodecItem item = stream
        .getOrFirst(streamIndex)
        .format
        .getOrFirst(formatIndex)
        .codec
        .getOrFirst(codecIndex);
    // 以服务端返回的码率为准
    currentQn = item.currentQn;
    acceptQnList = item.acceptQn.map((e) {
      return (
        code: e,
        desc: LiveQuality.fromCode(e)?.desc ?? e.toString(),
      );
    }).toList();
    currentQnDesc.value =
        LiveQuality.fromCode(currentQn)?.desc ?? currentQn.toString();
    videoUrl = VideoUtils.getLiveCdnUrl(item, index: liveUrlIndex);
    return playerInit()?.whenComplete(_startSizeSub);
  }

  Future<void> queryLiveInfoH5() async {
    final res = await LiveHttp.liveRoomInfoH5(roomId: roomId);
    if (res case Success(:final response)) {
      roomInfoH5.value = response;
      title.value = response.roomInfo?.title ?? '';
      watchedShow.value = response.watchedShow?.textLarge;
      videoPlayerServiceHandler?.onVideoDetailChange(response, roomId, heroTag);
    } else {
      res.toast();
    }
  }

  void _showDialog(String title) {
    showDialog(
      context: Get.context!,
      builder: (_) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '关闭',
              style: TextStyle(color: ThemeUtils.theme.colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () {
              if (plPlayerController.isDesktopPip) {
                plPlayerController.exitDesktopPip();
              }
              Get
                ..back()
                ..back();
            },
            child: const Text('退出'),
          ),
        ],
      ),
    );
  }

  void scrollToBottom() {
    ActionThrottle.run(
      'liveDm:$heroTag',
      const Duration(milliseconds: 500),
      () => WidgetsBinding.instance.addPostFrameCallback(_scrollToBottom),
    );
  }

  void _scrollToBottom([_]) {
    if (!isClosed && _followingLatest && scrollController.hasClients) {
      scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 500),
        curve: Curves.linearToEaseOut,
      );
    }
  }

  void handleJumpToBottom() {
    disableAutoScroll.value = false;
    chatBuffer.resume();
    _flushMessageRefresh();
    _jumpToBottom();
    WidgetsBinding.instance.addPostFrameCallback(_jumpToBottom);
  }

  void _jumpToBottom([_]) {
    if (!isClosed && _followingLatest && scrollController.hasClients) {
      scrollController.jumpTo(0);
    }
  }

  void closeLiveMsg() {
    _msgStream?.close();
    _msgStream = null;
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> prefetch() async {
    final res = await LiveHttp.liveRoomDmPrefetch(roomId: roomId);
    if (res case Success(:final response)) {
      if (response != null && response.isNotEmpty) {
        if (isClosed) return;
        for (final item in response) {
          if (!isBlocked(item.text, item.extra.mid)) addDm(item);
        }
        _flushMessageRefresh();
        scrollToBottom();
      }
    } else {
      if (kDebugMode) {
        Utils.reportError(res.toString());
      }
    }
  }

  Future<void> getSuperChatMsg() async {
    final res = await LiveHttp.superChatMsg(roomId);
    if (res.dataOrNull?.list case final list? when list.isNotEmpty) {
      superChatMsg.addAll(list);
    }
  }

  void clearSC() {
    superChatMsg.removeWhere((e) => e.expired);
  }

  Future<void> _fetchBlockRules() async {
    final res = await LiveHttp.getLiveInfoByUser(roomId);
    if (res case Success(:final response?)) {
      if (response.keywordList case final keywordList?) {
        _keywordList = keywordList;
      }
      if (response.shieldUserList case final shieldUserList?) {
        _shieldUids = shieldUserList.map((e) => e.uid).toSet();
      }
    }
  }

  void updateBlockRules(List<String> keywords, Set<int> uids) {
    _keywordList = keywords;
    _shieldUids = uids;
  }

  bool isBlocked(String text, Object uid) {
    return _shieldUids.contains(uid) || _keywordList.any(text.contains);
  }

  void startLiveMsg() {
    if (chatBuffer.historyCount == 0 && chatBuffer.pendingCount == 0) {
      prefetch();
      if (showSuperChat) {
        getSuperChatMsg();
      }
    }
    if (_msgStream != null) {
      return;
    }
    if (dmInfo != null) {
      initDm(dmInfo!);
      return;
    }
    LiveHttp.liveRoomGetDanmakuToken(roomId: roomId).then((res) {
      if (res case Success(:final response)) {
        initDm(dmInfo = response);
      }
    });
  }

  void listener() {
    final userScrollDirection = scrollController.position.userScrollDirection;
    if (userScrollDirection == .reverse) {
      disableAutoScroll.value = true;
      chatBuffer.pause();
    } else if (userScrollDirection == .forward) {
      final pos = scrollController.position;
      if (pos.pixels <= 100 && disableAutoScroll.value) {
        disableAutoScroll.value = false;
        refreshMsgIfNeeded();
      }
    }
  }

  void refreshMsgIfNeeded() {
    if (isClosed) return;
    if (_followingLatest) chatBuffer.resume();
    _flushMessageRefresh();
    if (_followingLatest) scrollToBottom();
  }

  @override
  void onClose() {
    _stopSizeSub();
    closeLiveMsg();
    cancelLikeTimer();
    cancelLiveTimer();
    _messageRefreshTimer?.cancel();
    _messageRefreshTimer = null;
    ActionThrottle.cancel('liveDm:$heroTag');
    savedDanmaku?.clear();
    savedDanmaku = null;
    chatBuffer.clear();
    messages.value = const [];
    if (showSuperChat) {
      superChatMsg.clear();
      fsSC.value = null;
    }
    scrollController
      ..removeListener(listener)
      ..dispose();
    pageController?.dispose();
    danmakuController = null;
    super.onClose();
  }

  // 修改画质
  Future<void>? changeQn(int qn) {
    if (currentQn == qn) {
      return null;
    }
    currentQn = qn;
    currentQnDesc.value =
        LiveQuality.fromCode(currentQn)?.desc ?? currentQn.toString();
    return queryLiveUrl();
  }

  void initDm(LiveDmInfoData info) {
    if (info.hostList.isEmpty) {
      return;
    }
    _msgStream =
        LiveMessageStream(
            streamToken: info.token,
            roomId: roomId,
            uid: Accounts.heartbeat.mid,
            servers: info.hostList
                .map((host) => 'wss://${host.host}:${host.wssPort}/sub')
                .toList(),
          )
          ..addEventListener(_danmakuListener)
          ..init();
  }

  void addDm(dynamic msg, [DanmakuContentItem<DanmakuExtra>? item]) {
    if (isClosed) return;

    if (plPlayerController.showDanmaku) {
      if (item != null && plPlayerController.enableShowLiveDanmaku.value) {
        danmakuController?.addDanmaku(item);
      }
      if (_followingLatest) {
        chatBuffer
          ..resume()
          ..add(msg);
        _scheduleMessageRefresh();
        scrollToBottom();
        return;
      }
    }

    chatBuffer
      ..pause()
      ..add(msg);
    _scheduleMessageRefresh();
  }

  void _addEmoteDanmaku(
    String text, {
    required LiveDanmaku extra,
    required Map<String, BaseEmote> emotes,
    required Color color,
    required DanmakuItemType type,
    required bool selfSend,
  }) {
    if (!plPlayerController.showDanmaku ||
        !plPlayerController.enableShowLiveDanmaku.value ||
        danmakuController == null) {
      return;
    }
    unawaited(() async {
      final fontSize = danmakuController?.option.fontSize ?? 25.0;
      final inlineImages = <DanmakuInlineImage>[];
      DanmakuContentItem<DanmakuExtra>? item;
      try {
        for (final entry in emotes.entries) {
          if (entry.key.isEmpty || !text.contains(entry.key)) continue;
          final emote = entry.value;
          final naturalWidth = emote.width.isFinite && emote.width > 0
              ? emote.width
              : fontSize;
          final naturalHeight = emote.height.isFinite && emote.height > 0
              ? emote.height
              : fontSize;
          final scale = math.min(
            1.0,
            fontSize * 1.5 / math.max(naturalWidth, naturalHeight),
          );
          final width = naturalWidth * scale;
          final height = naturalHeight * scale;
          final image = await _loadDanmakuEmote(emote.url);
          if (image != null) {
            inlineImages.add(
              DanmakuInlineImage(
                placeholder: entry.key,
                image: image,
                width: width,
                height: height,
              ),
            );
          }
        }
        item = DanmakuContentItem<DanmakuExtra>(
          text,
          color: color,
          type: type,
          selfSend: selfSend,
          extra: extra,
          inlineImages: inlineImages,
        );
        final controller = danmakuController;
        if (isClosed ||
            !plPlayerController.showDanmaku ||
            !plPlayerController.enableShowLiveDanmaku.value ||
            controller == null ||
            !controller.addDanmaku(item)) {
          item.dispose();
        }
      } catch (_) {
        if (item != null) {
          item.dispose();
        } else {
          for (final image in inlineImages) {
            image.image.dispose();
          }
        }
      }
    }());
  }

  Future<ui.Image?> _loadDanmakuEmote(String url) async {
    try {
      final stream = CachedImageProvider(
        ImageUtils.thumbnailUrl(url),
        maxDecodePixels: 1 << 16,
      ).resolve(ImageConfiguration.empty);
      final completer = Completer<ui.Image?>();
      late final ImageStreamListener listener;
      late final Timer timeout;
      void finish(ui.Image? image) {
        if (completer.isCompleted) {
          image?.dispose();
          return;
        }
        completer.complete(image);
        timeout.cancel();
        stream.removeListener(listener);
      }

      listener = ImageStreamListener(
        (info, _) {
          final image = info.image.clone();
          info.dispose();
          finish(image);
        },
        onError: (Object _, StackTrace? _) => finish(null),
      );
      timeout = Timer(const Duration(seconds: 5), () => finish(null));
      stream.addListener(listener);
      return await completer.future;
    } catch (_) {
      return null;
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  void _danmakuListener(dynamic obj) {
    try {
      // logger.i(' 原始弹幕消息 ======> ${jsonEncode(obj)}');
      switch (obj['cmd']) {
        case 'DANMU_MSG':
          final info = obj['info'];
          final first = info[0];
          final content = first[15];
          final user = content['user'];
          // final midHash = first[7];
          final uid = user['uid'];
          final msg = info[1];
          if (isBlocked(msg, uid)) {
            return;
          }
          final Map<String, dynamic> extra = jsonDecode(content['extra']);
          final name = user['base']['name'];
          BaseEmote? uemote;
          if (first[13] case Map<String, dynamic> map) {
            uemote = BaseEmote.fromJson(map);
          }
          final checkInfo = info[9];
          final liveExtra = LiveDanmaku(
            id: extra['id_str'],
            mid: uid,
            dmType: extra['dm_type'],
            ts: checkInfo['ts'],
            ct: checkInfo['ct'],
          );
          Owner? reply;
          final replyMid = extra['reply_mid'];
          if (replyMid != null && replyMid != 0) {
            reply = Owner(
              mid: replyMid,
              name: extra['reply_uname'],
            );
          }
          final emots = (extra['emots'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, BaseEmote.fromJson(v)),
          );
          final danmaku = DanmakuMsg(
            name: name,
            text: msg,
            emots: emots,
            uemote: uemote,
            extra: liveExtra,
            reply: reply,
            medalInfo: !GlobalData().showMedal || user['medal'] == null
                ? null
                : UinfoMedal.fromJson(user['medal']),
          );
          final danmakuContent = DanmakuContentItem<DanmakuExtra>(
            msg,
            color: DanmakuOptions.blockColorful
                ? Colors.white
                : DmUtils.decimalToColor(extra['color']),
            type: DmUtils.getPosition(extra['mode']),
            // extra['send_from_me'] is invalid
            selfSend: isLogin && uid == mid,
            extra: liveExtra,
          );
          if (uemote != null || emots?.isNotEmpty == true) {
            addDm(danmaku);
            final emoteText = msg.isEmpty && uemote != null
                ? uemote.emoticonUnique
                : msg;
            _addEmoteDanmaku(
              emoteText,
              extra: liveExtra,
              emotes: uemote == null ? emots! : {emoteText: uemote},
              color: danmakuContent.color,
              type: danmakuContent.type,
              selfSend: danmakuContent.selfSend,
            );
          } else {
            addDm(danmaku, danmakuContent);
          }
          break;
        case 'SUPER_CHAT_MESSAGE' when showSuperChat:
          final item = SuperChatItem.fromJson(obj['data'], roomId);
          superChatMsg.insert(0, item);
          addDm(item);
          if (Platform.isAndroid && AndroidHelper.isPipMode) return;
          if (plPlayerController.showDanmaku &&
              (isFullScreen || plPlayerController.isDesktopPip)) {
            fsSC.value = item.copyWith(
              endTime: math.min(
                item.endTime,
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 10,
              ),
            );
          }
          break;
        // case 'SUPER_CHAT_MESSAGE_DELETE' when showSuperChat:
        //   if (obj['roomid'] == roomId) {
        //     final ids = obj['data']?['ids'] as List?;
        //     if (ids != null && ids.isNotEmpty) {
        //       if (superChatType == .valid) {
        //         superChatMsg.removeWhere((e) => ids.contains(e.id));
        //       } else {
        //         bool? refresh;
        //         for (final id in ids) {
        //           if (superChatMsg.firstWhereOrNull((e) => e.id == id)
        //               case final item?) {
        //             item.deleted = true;
        //             refresh ??= true;
        //           }
        //         }
        //         if (refresh ?? false) {
        //           superChatMsg.refresh();
        //         }
        //       }
        //     }
        //   }
        case 'WATCHED_CHANGE':
          watchedShow.value = obj['data']['text_large'];
          break;
        case 'ONLINE_RANK_COUNT':
          onlineCount.value = NumUtils.numFormat(obj['data']['count']);
          break;
        case 'ROOM_CHANGE':
          title.value = obj['data']['title'];
          break;
      }
    } catch (e, s) {
      if (kDebugMode) {
        Utils.reportError(e, s);
      }
    }
  }

  final RxInt likeClickTime = 0.obs;
  Timer? likeClickTimer;

  void cancelLikeTimer() {
    likeClickTimer?.cancel();
    likeClickTimer = null;
  }

  void onLikeTapDown(_) {
    cancelLikeTimer();
    likeClickTime.value++;
  }

  void onLikeTapUp([_]) {
    likeClickTimer ??= Timer(const Duration(milliseconds: 800), onLike);
  }

  Future<void> onLike() async {
    if (!isLogin) {
      likeClickTime.value = 0;
      return;
    }
    final res = await LiveHttp.liveLikeReport(
      clickTime: likeClickTime.value,
      roomId: roomId,
      uid: mid,
      anchorId: roomInfoH5.value?.roomInfo?.uid,
    );
    if (res.isSuccess) {
      SmartDialog.showToast('点赞成功');
    } else {
      res.toast();
    }
    likeClickTime.value = 0;
  }

  void toastNotLogin() {
    SmartDialog.showToast('账号未登录');
  }

  void onSendDanmaku([bool fromEmote = false]) {
    if (kReleaseMode && !isLogin) {
      toastNotLogin();
      return;
    }
    Get.key.currentState!.push(
      PublishRoute(
        barrierColor: Colors.transparent,
        pageBuilder: (context, animation, secondaryAnimation) {
          return Theme(
            data: ThemeUtils.darkTheme,
            child: LiveSendDmPanel(
              fromEmote: fromEmote,
              liveRoomController: this,
              items: savedDanmaku,
              autofocus: !fromEmote,
              onSave: (msg) {
                if (msg.isEmpty) {
                  savedDanmaku?.clear();
                  savedDanmaku = null;
                } else {
                  savedDanmaku = msg.toList();
                }
              },
            ),
          );
        },
        transitionDuration: fromEmote
            ? const Duration(milliseconds: 400)
            : PlatformUtils.isDesktop
            ? const Duration(milliseconds: 350)
            : const Duration(milliseconds: 400),
      ),
    );
  }

  void onAtUser(DanmakuMsg item) {
    savedDanmaku = [
      RichTextItem.fromStart(
        '@${item.name} ',
        rawText: item.extra.mid.toString(),
        type: .at,
        id: item.extra.id.toString(),
      ),
    ];
    onSendDanmaku();
  }

  void reportSC(SuperChatItem item) {
    if (!isLogin) {
      toastNotLogin();
      return;
    }
    autoWrapReportDialog(
      Get.context!,
      ban: false,
      ReportOptions.liveDanmakuReport,
      withContent: ReportOptions.liveDanmakuReportCheck,
      contentRequired: ReportOptions.liveDanmakuReportCheck,
      (reasonType, reasonDesc, banUid) {
        return LiveHttp.superChatReport(
          id: item.id,
          roomId: roomId,
          uid: item.uid,
          msg: item.message,
          reason: ReportOptions.liveDanmakuReport['']![reasonType]!,
          ts: item.ts,
          token: item.token,
        );
      },
    );
  }
}

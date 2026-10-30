import 'package:pili_aurora/pages/danmaku/live_layer.dart';
import 'package:pili_aurora/pages/danmaku/display_binding.dart';

import 'dart:io';

import 'package:pili_aurora/services/desktop_playback_request.dart';

import 'dart:math';
import 'dart:ui';

import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/button/icon_button.dart';
import 'package:pili_aurora/common/widgets/custom_icon.dart';
import 'package:pili_aurora/common/widgets/extra_hittest_stack.dart';
import 'package:pili_aurora/common/widgets/flutter/pop_scope.dart';
import 'package:pili_aurora/common/widgets/gesture/horizontal_drag_gesture_recognizer.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/keep_alive_wrapper.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart'
    show tabBarScrollPhysics;
import 'package:pili_aurora/models/common/live/live_contribution_rank_type.dart';
import 'package:pili_aurora/models/remote/live/live_room_info_h5/data.dart';
import 'package:pili_aurora/models/remote/live/live_superchat/item.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/frame_rate_setting.dart';
import 'package:pili_aurora/pages/live_room/contribution_rank/controller.dart';
import 'package:pili_aurora/pages/live_room/contribution_rank/view.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/pages/live_room/superchat/superchat_card.dart';
import 'package:pili_aurora/pages/live_room/superchat/superchat_panel.dart';
import 'package:pili_aurora/pages/live_room/widgets/bottom_control.dart';
import 'package:pili_aurora/pages/live_room/widgets/chat_panel.dart';
import 'package:pili_aurora/pages/live_room/widgets/desktop_sidebar.dart';
import 'package:pili_aurora/pages/live_room/widgets/header_control.dart';
import 'package:pili_aurora/pages/live_room/widgets/live_list_sheet.dart';
import 'package:pili_aurora/pages/video/widgets/player_focus.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_status.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:pili_aurora/plugin/pl_player/utils/danmaku_options.dart';
import 'package:pili_aurora/plugin/pl_player/utils/fullscreen.dart';
import 'package:pili_aurora/plugin/pl_player/view/view.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/player_loading.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/utils/android/bindings.g.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/extension/size_ext.dart';
import 'package:pili_aurora/utils/extension/theme_ext.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/utils/max_screen_size.dart';
import 'package:pili_aurora/utils/mobile_observer.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/share_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

const baseWhite = Color(0xFFEEEEEE);

class LiveRoomPage extends StatefulWidget {
  const LiveRoomPage({super.key});

  @override
  State<LiveRoomPage> createState() => _LiveRoomPageState();
}

class _LiveRoomPageState extends State<LiveRoomPage>
    with WidgetsBindingObserver, RouteAware, RouteAwareMixin {
  late final fullScreenSCWidth = Pref.fullScreenSCWidth;
  final String heroTag = Utils.generateRandomString(6);
  late final LiveRoomController _liveRoomController;
  late final PlPlayerController plPlayerController;
  bool get isFullScreen => plPlayerController.isFullScreen.value;

  late final GlobalKey pageKey = GlobalKey();
  late final GlobalKey chatKey = GlobalKey();
  late final GlobalKey scKey = GlobalKey();
  late final GlobalKey playerKey = GlobalKey();
  late final GlobalKey desktopSidebarKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    addObserverMobile(this);
    _liveRoomController = Get.put(
      LiveRoomController(heroTag),
      tag: heroTag,
    );
    plPlayerController = _liveRoomController.plPlayerController
      ..desktopPlaybackRequest = (() =>
          DesktopPlaybackRequest.live(_liveRoomController.roomId))
      ..addStatusLister(playerListener);
    PlPlayerController.setPlayCallBack(
      plPlayerController.play,
      owner: this,
    );
    if (plPlayerController.removeSafeArea) {
      hideSystemBar();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (plPlayerController.removeSafeArea) {
      padding = .zero;
    } else {
      padding = MediaQuery.viewPaddingOf(context);
    }
    final size = MediaQuery.sizeOf(context);
    maxWidth = size.width;
    maxHeight = size.height;
    isWindowMode = MaxScreenSize.isWindowMode(
      width: maxWidth * plPlayerController.uiScale,
      height: maxHeight * plPlayerController.uiScale,
    );
    isPortrait = size.isPortrait;
    plPlayerController.screenRatio = maxHeight / maxWidth;
  }

  @override
  Future<void> didPopNext() async {
    final restore = _liveRoomController.restorePlaybackAfterRoute();
    addObserverMobile(this);
    if (!plPlayerController.isLive) {
      plPlayerController.isLive = true;
    }
    PlPlayerController.setPlayCallBack(
      plPlayerController.play,
      owner: this,
    );
    plPlayerController.notifyDanmakuOptionsChanged();
    _liveRoomController.startLiveTimer();
    plPlayerController.addStatusLister(playerListener);
    playerListener(plPlayerController.playerStatus);
    super.didPopNext();
    await restore;
    if (!mounted) return;
  }

  @override
  void didPushNext() {
    removeObserverMobile(this);
    plPlayerController.removeStatusLister(playerListener);
    plPlayerController.clearDanmakuDisplay();
    _liveRoomController
      ..holdPlaybackForRoute()
      ..cancelLiveTimer()
      ..closeLiveMsg();
    super.didPushNext();
  }

  void playerListener(PlayerStatus status) {
    if (status.isPlaying) {
      _liveRoomController
        ..startLiveTimer()
        ..startLiveMsg();
    } else {
      _liveRoomController
        ..cancelLiveTimer()
        ..closeLiveMsg();
    }
  }

  @override
  void dispose() {
    removeObserverMobile(this);
    videoPlayerServiceHandler?.onVideoDetailDispose(heroTag);
    if (Platform.isAndroid && !plPlayerController.setSystemBrightness) {
      ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
    }
    PlPlayerController.setPlayCallBack(null, owner: this);
    plPlayerController.removeStatusLister(playerListener);
    for (final e in LiveContributionRankType.values) {
      Get.delete<ContributionRankController>(
        tag: '${_liveRoomController.roomId}${e.name}',
      );
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (plPlayerController.visible = state == .resumed) {
      if (!plPlayerController.showDanmaku) {
        _liveRoomController
          ..refreshMsgIfNeeded()
          ..startLiveTimer();
        plPlayerController.showDanmaku = true;
      }
    } else if (state == .paused) {
      _liveRoomController.cancelLiveTimer();
      plPlayerController
        ..showDanmaku = false
        ..clearDanmakuDisplay();
    }
  }

  late double maxWidth;
  late double maxHeight;
  bool isWindowMode = false;
  late EdgeInsets padding;
  late bool isPortrait;

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (Platform.isAndroid && AndroidHelper.isPipMode) {
      child = videoPlayerPanel(
        isFullScreen,
        width: maxWidth,
        height: maxHeight,
        isPipMode: true,
        needDm: !plPlayerController.pipNoDanmaku,
      );
    } else {
      child = childWhenDisabled;
    }
    if (plPlayerController.keyboardControl) {
      child = PlayerFocus(
        plPlayerController: plPlayerController,
        onSendDanmaku: _liveRoomController.onSendDanmaku,
        onRefresh: _liveRoomController.queryLiveUrl,
        child: child,
      );
    }
    return Theme(
      data: ThemeUtils.darkTheme,
      child: child,
    );
  }

  Widget videoPlayerPanel(
    bool isFullScreen, {
    required double width,
    required double height,
    bool isPipMode = false,
    Color fill = Colors.black,
    Alignment alignment = Alignment.center,
    bool needDm = true,
  }) {
    if (!isFullScreen && !plPlayerController.isDesktopPip) {
      _liveRoomController.fsSC.value = null;
    }
    _liveRoomController.isFullScreen = isFullScreen;
    Widget player = Obx(
      key: playerKey,
      () {
        if (!plPlayerController.isLive) return const SizedBox.shrink();
        final roomInfoH5 = _liveRoomController.roomInfoH5.value;
        final header = LiveHeaderControl(
          key: _liveRoomController.headerKey,
          title: roomInfoH5?.roomInfo?.title,
          upName: roomInfoH5?.anchorInfo?.baseInfo?.uname,
          plPlayerController: plPlayerController,
          onSendDanmaku: _liveRoomController.onSendDanmaku,
          onPlayAudio: _liveRoomController.queryLiveUrl,
          isPortrait: isPortrait,
          liveController: _liveRoomController,
          onlineWidget: onlineWidget,
        );
        final bottom = BottomControl(
          plPlayerController: plPlayerController,
          liveRoomCtr: _liveRoomController,
          onRefresh: _liveRoomController.queryLiveUrl,
        );
        return ValueListenableBuilder(
          valueListenable: plPlayerController.videoControllerListenable,
          builder: (context, videoController, _) {
            if (videoController == null) {
              return SizedBox(
                width: width,
                height: height,
                child: Obx(
                  () => PlayerLoadingPanel(
                    headerControl: header,
                    bottomControl: bottom,
                    failed: plPlayerController.dataStatus.error,
                    onRetry: _liveRoomController.retryPlayback,
                    fill: fill,
                  ),
                ),
              );
            }
            return PLVideoPlayer(
              maxWidth: width,
              maxHeight: height,
              fill: fill,
              alignment: alignment,
              plPlayerController: plPlayerController,
              onRetry: _liveRoomController.retryPlayback,
              headerControl: header,
              bottomControl: bottom,
              danmuWidget: !needDm
                  ? null
                  : LiveDanmaku(
                      liveRoomController: _liveRoomController,
                      plPlayerController: plPlayerController,
                      isFullScreen: isFullScreen,
                      isPipMode: plPlayerController.isDesktopPip || isPipMode,
                      size: Size(width, height),
                    ),
            );
          },
        );
      },
    );
    if (_liveRoomController.showSuperChat &&
        (isFullScreen || plPlayerController.isDesktopPip)) {
      player = Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: player),
          if (kDebugMode) ...[
            Positioned(
              top: 50,
              right: 0,
              child: TextButton(
                onPressed: () {
                  final item = SuperChatItem.random;
                  _liveRoomController
                    ..fsSC.value = item
                    ..addDm(item);
                },
                child: const Text('add superchat'),
              ),
            ),
            Positioned(
              right: 0,
              top: 90,
              child: TextButton(
                onPressed: () {
                  _liveRoomController.fsSC.value = null;
                },
                child: const Text('remove superchat'),
              ),
            ),
          ],
          Positioned(
            left: padding.left + 25,
            bottom: 25,
            width: fullScreenSCWidth,
            child: Obx(() {
              final item = _liveRoomController.fsSC.value;
              if (item == null) {
                return const SizedBox.shrink();
              }
              try {
                return ExtraHitTestStack(
                  key: ValueKey(item.id),
                  clipBehavior: Clip.none,
                  children: [
                    SuperChatCard(
                      item: item,
                      onRemove: () => _liveRoomController.fsSC.value = null,
                      onReport: () => _liveRoomController.reportSC(item),
                    ),
                    Positioned(
                      right: -6,
                      top: -6,
                      child: iconButton(
                        size: 24,
                        iconSize: 14,
                        bgColor: const Color(0xEEFFFFFF),
                        iconColor: Colors.black54,
                        icon: const Icon(Icons.clear),
                        onPressed: () => _liveRoomController.fsSC.value = null,
                      ),
                    ),
                  ],
                );
              } catch (_) {
                if (kDebugMode) rethrow;
                return const SizedBox.shrink();
              }
            }),
          ),
        ],
      );
    }
    return popScope(
      canPop: !isFullScreen && !plPlayerController.isDesktopPip,
      onPopInvokedWithResult: plPlayerController.onPopInvokedWithResult,
      child: player,
    );
  }

  Widget get childWhenDisabled {
    return Obx(() {
      final isFullScreen = this.isFullScreen || plPlayerController.isDesktopPip;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          const SizedBox.expand(child: ColoredBox(color: Colors.black)),
          if (!isFullScreen)
            Obx(
              () {
                final appBackground = _liveRoomController
                    .roomInfoH5
                    .value
                    ?.roomInfo
                    ?.appBackground;
                Widget child;
                if (appBackground != null && appBackground.isNotEmpty) {
                  child = CachedImage(
                    fit: BoxFit.cover,
                    width: maxWidth,
                    height: maxHeight,
                    memCacheWidth: maxWidth.cacheSize(context),
                    imageUrl: ImageUtils.safeThumbnailUrl(appBackground),
                    placeholder: (_, _) => const SizedBox.shrink(),
                  );
                } else {
                  child = Image.asset(
                    Assets.livingBackground,
                    fit: BoxFit.cover,
                    width: maxWidth,
                    height: maxHeight,
                    cacheWidth: maxWidth.cacheSize(context),
                  );
                }
                return Positioned.fill(
                  child: Opacity(opacity: 0.6, child: child),
                );
              },
            ),
          ScaffoldLayout(
            appBar: isWindowMode && isFullScreen && !isPortrait
                ? null
                : _buildAppBar(isFullScreen),
            body: isPortrait
                ? Obx(
                    () {
                      if (_liveRoomController.isPortrait.value) {
                        return _buildPP(isFullScreen);
                      }
                      return _buildPH(isFullScreen);
                    },
                  )
                : _buildBodyH(isFullScreen),
          ),
        ],
      );
    });
  }

  Widget _buildPH(bool isFullScreen) {
    final height = maxWidth / Style.aspectRatio16x9;
    final videoHeight = isFullScreen
        ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
        : height;
    final bottomHeight = maxHeight - padding.top - height - kToolbarHeight;
    return Column(
      children: [
        SizedBox(
          width: maxWidth,
          height: videoHeight,
          child: videoPlayerPanel(
            isFullScreen,
            width: maxWidth,
            height: videoHeight,
          ),
        ),
        Offstage(
          offstage: isFullScreen,
          child: SizedBox(
            width: maxWidth,
            height: max(0, bottomHeight),
            child: _buildBottomWidget,
          ),
        ),
      ],
    );
  }

  Widget _buildPP(bool isFullScreen) {
    final bottomHeight = 70 + padding.bottom;
    final videoHeight = isFullScreen
        ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
        : maxHeight - bottomHeight;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          bottom: isFullScreen ? 0 : bottomHeight,
          child: videoPlayerPanel(
            width: maxWidth,
            height: videoHeight,
            isFullScreen,
            needDm: isFullScreen,
            alignment: isFullScreen ? Alignment.center : Alignment.topCenter,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 55 + bottomHeight,
          height: maxHeight * 0.32,
          child: Offstage(
            offstage: isFullScreen,
            child: _buildChatWidget(true),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: bottomHeight,
          child: Offstage(
            offstage: isFullScreen,
            child: _buildInputWidget,
          ),
        ),
      ],
    );
  }

  Widget get onlineWidget => GestureDetector(
    onTap: _showRank,
    child: Obx(() {
      if (_liveRoomController.onlineCount.value case final onlineCount?) {
        return Text(
          '高能观众($onlineCount)',
          style: const TextStyle(fontSize: 12, color: Colors.white),
        );
      }
      return const SizedBox.shrink();
    }),
  );

  void _showRank() {
    if (_liveRoomController.ruid case final ruid?) {
      final heightFactor = PlatformUtils.isMobile && !isPortrait ? 1.0 : 0.7;
      showLiveListSheet(
        context: context,
        title: '房间观众',
        heightFactor: heightFactor,
        child: ContributionRankPanel(
          ruid: ruid,
          roomId: _liveRoomController.roomId,
        ),
      );
    }
  }

  PreferredSizeWidget _buildAppBar(bool isFullScreen) {
    return AppBar(
      primary: !plPlayerController.removeSafeArea,
      toolbarHeight: isFullScreen ? 0 : null,
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      titleTextStyle: const TextStyle(color: Colors.white),
      title: isFullScreen || plPlayerController.isDesktopPip
          ? null
          : Obx(
              () {
                RoomInfoH5Data? roomInfoH5 =
                    _liveRoomController.roomInfoH5.value;
                if (roomInfoH5 == null) {
                  return const SizedBox.shrink();
                }
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      Get.toNamed('/member?mid=${roomInfoH5.roomInfo?.uid}'),
                  child: Row(
                    spacing: 10,
                    mainAxisSize: .min,
                    children: [
                      NetworkImgLayer(
                        width: 34,
                        height: 34,
                        type: .avatar,
                        src: roomInfoH5.anchorInfo!.baseInfo!.face,
                      ),
                      Flexible(
                        child: Column(
                          spacing: 1,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              spacing: 10,
                              mainAxisSize: .min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Flexible(
                                  child: Text(
                                    roomInfoH5.anchorInfo!.baseInfo!.uname!,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                onlineWidget,
                              ],
                            ),
                            Row(
                              spacing: 10,
                              mainAxisSize: .min,
                              children: [
                                _liveRoomController.watchedWidget,
                                _liveRoomController.timeWidget,
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
      actions: [
        // IconButton(
        //   tooltip: '刷新',
        //   onPressed: _liveRoomController.queryLiveUrl,
        //   icon: const Icon(Icons.refresh, size: 20),
        // ),
        PopupMenuButton(
          icon: const Icon(Icons.more_vert, size: 20),
          itemBuilder: (BuildContext context) {
            final liveUrl =
                'https://live.bilibili.com/${_liveRoomController.roomId}';
            return <PopupMenuEntry>[
              PopupMenuItem(
                onTap: () => Utils.copyText(liveUrl),
                child: const Row(
                  spacing: 10,
                  mainAxisSize: .min,
                  children: [
                    Icon(Icons.copy, size: 19),
                    Text('复制链接'),
                  ],
                ),
              ),
              if (PlatformUtils.isMobile)
                PopupMenuItem(
                  onTap: () => ShareUtils.shareText(liveUrl),
                  child: const Row(
                    spacing: 10,
                    mainAxisSize: .min,
                    children: [
                      Icon(Icons.share, size: 19),
                      Text('分享直播间'),
                    ],
                  ),
                ),
              PopupMenuItem(
                onTap: () => PageUtils.inAppWebview(liveUrl, off: true),
                child: const Row(
                  spacing: 10,
                  mainAxisSize: .min,
                  children: [
                    Icon(Icons.open_in_browser, size: 19),
                    Text('浏览器打开'),
                  ],
                ),
              ),
              if (_liveRoomController.roomInfoH5.value != null)
                PopupMenuItem(
                  onTap: () {
                    try {
                      RoomInfoH5Data roomInfo =
                          _liveRoomController.roomInfoH5.value!;
                      PageUtils.pmShare(
                        this.context,
                        content: {
                          "cover": roomInfo.roomInfo!.cover!,
                          "sourceID": _liveRoomController.roomId.toString(),
                          "title": roomInfo.roomInfo!.title!,
                          "url": liveUrl,
                          "authorID": roomInfo.roomInfo!.uid.toString(),
                          "source": "直播",
                          "desc": roomInfo.roomInfo!.title!,
                          "author": roomInfo.anchorInfo!.baseInfo!.uname,
                        },
                      );
                    } catch (e) {
                      SmartDialog.showToast(e.toString());
                    }
                  },
                  child: const Row(
                    spacing: 10,
                    mainAxisSize: .min,
                    children: [
                      Icon(Icons.forward_to_inbox, size: 19),
                      Text('分享至消息'),
                    ],
                  ),
                ),
            ];
          },
        ),
      ],
    );
  }

  Widget _buildBodyH(bool isFullScreen) {
    double videoWidth =
        clampDouble(maxHeight / maxWidth * 1.08, 0.56, 0.7) * maxWidth;
    final rightWidth = min(400.0, maxWidth - videoWidth - padding.horizontal);
    videoWidth = maxWidth - rightWidth - padding.horizontal;
    final videoHeight = maxHeight - padding.top - kToolbarHeight;
    final width = isFullScreen ? maxWidth : videoWidth;
    final height = isFullScreen
        ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
        : videoHeight;
    return Padding(
      padding: isFullScreen
          ? EdgeInsets.zero
          : EdgeInsets.only(left: padding.left, right: padding.right),
      child: Row(
        children: [
          Container(
            width: width,
            height: height,
            margin: EdgeInsets.only(bottom: padding.bottom),
            child: videoPlayerPanel(
              isFullScreen,
              fill: Colors.transparent,
              width: width,
              height: height,
            ),
          ),
          Offstage(
            offstage: isFullScreen,
            child: SizedBox(
              width: rightWidth,
              height: videoHeight,
              child: DesktopLiveSidebar(
                key: desktopSidebarKey,
                roomId: _liveRoomController.roomId,
                anchorUid: _liveRoomController.roomInfoH5.value?.roomInfo?.uid,
                onShowRank: _showRank,
                anchorName: _liveRoomController
                    .roomInfoH5
                    .value
                    ?.anchorInfo
                    ?.baseInfo
                    ?.uname,
                liveRoomController: _liveRoomController,
                chat: _buildChatWidget(),
                input: _buildInputWidget,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget get _buildBottomWidget => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: _buildChatWidget()),
      _buildInputWidget,
    ],
  );

  Widget _buildChatWidget([bool isPP = false]) {
    Widget chat() => LiveRoomChatPanel(
      key: chatKey,
      isPP: isPP,
      liveRoomController: _liveRoomController,
    );
    return Padding(
      padding: .only(bottom: 12, top: isPortrait ? 12 : 0),
      child: _liveRoomController.showSuperChat
          ? PageView(
              key: pageKey,
              controller: _liveRoomController.pageController,
              physics: tabBarScrollPhysics,
              onPageChanged: _liveRoomController.pageIndex.call,
              horizontalDragGestureRecognizer:
                  CustomHorizontalDragGestureRecognizer.new,
              children: [
                KeepAliveWrapper(child: chat()),
                SuperChatPanel(
                  key: scKey,
                  controller: _liveRoomController,
                ),
              ],
            )
          : chat(),
    );
  }

  Widget get _buildInputWidget {
    final child = Container(
      padding: .only(top: 5, left: 10, right: 10, bottom: padding.bottom),
      height: 70 + padding.bottom,
      decoration: const BoxDecoration(
        borderRadius: .vertical(top: .circular(20)),
        border: Border(top: BorderSide(color: Color(0x1AFFFFFF))),
        color: Color(0x1AFFFFFF),
      ),
      child: GestureDetector(
        onTap: _liveRoomController.onSendDanmaku,
        behavior: .opaque,
        child: Padding(
          padding: const .only(top: 5, bottom: 10),
          child: Align(
            alignment: .topCenter,
            child: Row(
              spacing: 6,
              children: [
                Obx(
                  () {
                    final enableShowLiveDanmaku =
                        plPlayerController.enableShowLiveDanmaku.value;
                    return SizedBox(
                      width: 34,
                      height: 34,
                      child: IconButton(
                        style: IconButton.styleFrom(padding: .zero),
                        onPressed: () {
                          final newVal = !enableShowLiveDanmaku;
                          plPlayerController.enableShowLiveDanmaku.value =
                              newVal;
                          if (!plPlayerController.tempPlayerConf) {
                            GStorage.setting.put(
                              SettingBoxKey.enableShowLiveDanmaku,
                              newVal,
                            );
                          }
                        },
                        icon: enableShowLiveDanmaku
                            ? const Icon(
                                size: 22,
                                CustomIcons.dm_on,
                                color: baseWhite,
                              )
                            : const Icon(
                                size: 22,
                                CustomIcons.dm_off,
                                color: baseWhite,
                              ),
                      ),
                    );
                  },
                ),
                const Expanded(
                  child: Text('发送弹幕', style: TextStyle(color: baseWhite)),
                ),
                Builder(
                  builder: (context) {
                    final isLogin = kDebugMode || _liveRoomController.isLogin;
                    final colorScheme = ColorScheme.of(context);
                    return Material(
                      type: MaterialType.transparency,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          InkWell(
                            overlayColor: _overlayColor(colorScheme),
                            customBorder: const CircleBorder(),
                            onTap: isLogin
                                ? null
                                : _liveRoomController.toastNotLogin,
                            onTapDown: isLogin
                                ? _liveRoomController.onLikeTapDown
                                : null,
                            onTapUp: isLogin
                                ? _liveRoomController.onLikeTapUp
                                : null,
                            onTapCancel: isLogin
                                ? _liveRoomController.onLikeTapUp
                                : null,
                            child: const SizedBox.square(
                              dimension: 34,
                              child: Icon(
                                size: 22,
                                color: baseWhite,
                                Icons.thumb_up_off_alt,
                              ),
                            ),
                          ),
                          Positioned(
                            left: 30,
                            top: -12,
                            child: Obx(() {
                              final likeClickTime =
                                  _liveRoomController.likeClickTime.value;
                              if (likeClickTime == 0) {
                                return const SizedBox.shrink();
                              }
                              return AnimatedSwitcher(
                                duration: const Duration(milliseconds: 160),
                                transitionBuilder: (child, animation) {
                                  return ScaleTransition(
                                    scale: animation,
                                    child: child,
                                  );
                                },
                                child: Text(
                                  key: ValueKey(likeClickTime),
                                  'x$likeClickTime',
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: colorScheme.isDark
                                        ? colorScheme.primary
                                        : colorScheme.inversePrimary,
                                  ),
                                ),
                              );
                            }),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                SizedBox(
                  width: 34,
                  height: 34,
                  child: IconButton(
                    style: IconButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () => _liveRoomController.onSendDanmaku(true),
                    icon: const Icon(
                      size: 22,
                      color: baseWhite,
                      Icons.emoji_emotions_outlined,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (_liveRoomController.showSuperChat) {
      return Stack(
        children: [
          child,
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            child: Obx(
              () => _BorderIndicator(
                radius: const Radius.circular(20),
                isLeft: _liveRoomController.pageIndex.value == 0,
              ),
            ),
          ),
        ],
      );
    }
    return child;
  }

  WidgetStateProperty<Color?>? _overlayColor(ColorScheme colorScheme) =>
      WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        final color = states.contains(WidgetState.selected)
            ? colorScheme.primary
            : colorScheme.onSurfaceVariant;
        if (states.contains(WidgetState.pressed)) {
          return color.withValues(alpha: 0.1);
        } else if (states.contains(WidgetState.hovered)) {
          return color.withValues(alpha: 0.08);
        } else if (states.contains(WidgetState.focused)) {
          return color.withValues(alpha: 0.1);
        } else {
          return Colors.transparent;
        }
      });
}

class _BorderIndicator extends LeafRenderObjectWidget {
  const _BorderIndicator({
    required this.radius,
    required this.isLeft,
  });

  final Radius radius;
  final bool isLeft;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderBorderIndicator(
      radius: radius,
      isLeft: isLeft,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderBorderIndicator renderObject,
  ) {
    renderObject
      ..radius = radius
      ..isLeft = isLeft;
  }
}

class _RenderBorderIndicator extends RenderBox {
  _RenderBorderIndicator({
    required this._radius,
    required this._isLeft,
  });

  Radius _radius;
  Radius get radius => _radius;
  set radius(Radius value) {
    if (_radius == value) return;
    _radius = value;
    markNeedsLayout();
  }

  bool _isLeft;
  bool get isLeft => _isLeft;
  set isLeft(bool value) {
    if (_isLeft == value) return;
    _isLeft = value;
    markNeedsPaint();
  }

  @override
  void performLayout() {
    size = constraints.constrainDimensions(constraints.maxWidth, _radius.x);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final size = this.size;
    final canvas = context.canvas;
    final width = size.width / 2;

    BoxBorder.paintNonUniformBorder(
      canvas,
      Rect.fromLTWH(
        offset.dx + (_isLeft ? 0 : width),
        offset.dy,
        width,
        size.height,
      ),
      borderRadius: BorderRadius.only(
        topLeft: _isLeft ? _radius : .zero,
        topRight: _isLeft ? .zero : _radius,
      ),
      textDirection: null,
      top: const BorderSide(),
      color: Colors.white38,
    );
  }
}

class LiveDanmaku extends StatefulWidget {
  final LiveRoomController liveRoomController;
  final PlPlayerController plPlayerController;
  final bool isPipMode;
  final bool isFullScreen;
  final Size size;

  const LiveDanmaku({
    super.key,
    required this.liveRoomController,
    required this.plPlayerController,
    this.isPipMode = false,
    required this.isFullScreen,
    required this.size,
  });

  @override
  State<LiveDanmaku> createState() => _LiveDanmakuState();

  bool get notFullscreen => !isFullScreen || isPipMode;
}

class _LiveDanmakuState extends State<LiveDanmaku> {
  PlPlayerController get player => widget.plPlayerController;
  DanmakuDisplayBinding? _binding;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    player.addStatusLister(_statusChanged);
    player.addDanmakuOptionsListener(_optionsChanged);
  }

  void _statusChanged(PlayerStatus _) => _optionsChanged();
  void _syncBinding() {
    if (_enabled && player.isLive && _binding != null) {
      player.danmakuDisplay = _binding;
    } else if (identical(player.danmakuDisplay, _binding)) {
      player.danmakuDisplay = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled = TickerMode.valuesOf(context).enabled;
    _syncBinding();
  }

  void _optionsChanged() {
    _syncBinding();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => DanmakuFrameRateSetting(
    builder: (context, frameRate) => Obx(() {
      final opacity = player.enableShowLiveDanmaku.value
          ? player.danmakuOpacity.value
          : 0.0;
      return Opacity(
        opacity: opacity,
        child: LiveDanmakuLayer<DanmakuExtra>(
          messages: widget.liveRoomController.liveDanmakuMessages,
          running: player.playerStatus.isPlaying,
          visible: opacity > 0 && player.showDanmaku,
          option: DanmakuOptions.get(notFullscreen: widget.notFullscreen),
          size: widget.size,
          frameRate: frameRate,
          frameSource: player.frameSource,
          createdInteraction: (interaction, clear) {
            _binding = DanmakuDisplayBinding(
              interaction: interaction,
              clear: clear,
            );
            _syncBinding();
          },
        ),
      );
    }),
  );

  @override
  void dispose() {
    player.removeStatusLister(_statusChanged);
    player.removeDanmakuOptionsListener(_optionsChanged);
    if (identical(player.danmakuDisplay, _binding)) {
      player.danmakuDisplay = null;
    }
    super.dispose();
  }
}

import 'dart:convert';

import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/controller.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/render_guard.dart';
import 'package:pili_aurora/pages/danmaku/windows_renderer.dart';
import 'package:pili_aurora/pages/danmaku/windows_screen.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:pili_aurora/plugin/pl_player/utils/danmaku_options.dart';
import 'package:pili_aurora/utils/danmaku_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 传入播放器控制器，监听播放进度，加载对应弹幕
class PlDanmaku extends StatefulWidget {
  final int cid;
  final PlPlayerController playerController;
  final bool isPipMode;
  final bool isFullScreen;
  final bool isFileSource;
  final Size size;

  const PlDanmaku({
    super.key,
    required this.cid,
    required this.playerController,
    this.isPipMode = false,
    required this.isFullScreen,
    required this.isFileSource,
    required this.size,
  });

  @override
  State<PlDanmaku> createState() => _PlDanmakuState();

  bool get notFullscreen => !isFullScreen || isPipMode;
}

class _PlDanmakuState extends State<PlDanmaku> {
  static const _windowsPreprocess = bool.fromEnvironment(
    'WINDOWS_DANMAKU_PREPROCESS',
    defaultValue: true,
  );
  static const _maxDanmakuPerTick = 120;
  static const _maxActiveDanmaku = 600;
  static const _maxSpecialPerTick = 4;
  static const _maxActiveSpecialDanmaku = 32;

  PlPlayerController get playerController => widget.playerController;

  late final PlDanmakuController _plDanmakuController;
  DanmakuController<DanmakuExtra>? _controller;
  WindowsDanmakuRenderer<DanmakuExtra>? _windowsRenderer;
  int _lastPreparedPosition = -1;
  int latestAddedPosition = -1;

  @override
  void initState() {
    super.initState();
    _plDanmakuController = PlDanmakuController(
      widget.cid,
      playerController,
      widget.isFileSource,
    );
    if (playerController.enableShowDanmaku.value) {
      if (widget.isFileSource) {
        _plDanmakuController.initFileDmIfNeeded();
      } else {
        _plDanmakuController.queryDanmaku(
          DmUtils.calcSegment(playerController.positionInMilliseconds),
        );
      }
    }
    playerController
      ..addStatusLister(playerListener)
      ..addPositionListener(videoPositionListen);
  }

  @override
  void didUpdateWidget(PlDanmaku oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notFullscreen != widget.notFullscreen &&
        !DanmakuOptions.sameFontScale) {
      _controller?.updateOption(
        DanmakuOptions.get(notFullscreen: widget.notFullscreen),
      );
    }
  }

  // 播放器状态监听
  void playerListener(PlayerStatus status) {
    if (_controller case final controller?) {
      if (status.isPlaying) {
        controller.resume();
      } else {
        controller.pause();
      }
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  void videoPositionListen(Duration position) {
    if (!playerController.enableShowDanmaku.value) {
      return;
    }

    if (!playerController.showDanmaku && !widget.isPipMode) {
      return;
    }

    if (!playerController.playerStatus.isPlaying) {
      return;
    }

    final controller = _controller;
    if (controller == null) return;
    final trackCount = controller.trackCount;
    if (trackCount <= 0) {
      // canvas_danmaku 在零轨道时仍可能访问第一个轨道；海量模式
      // 还会执行 nextInt(0)。尺寸切换时跳过本次批次。
      return;
    }

    int currentPosition = position.inMilliseconds;
    currentPosition -= currentPosition % 100; //取整百的毫秒数
    if (currentPosition == latestAddedPosition) {
      return;
    }
    latestAddedPosition = currentPosition;

    List<DanmakuElem>? currentDanmakuList = _plDanmakuController
        .getCurrentDanmaku(currentPosition);
    if (currentDanmakuList != null) {
      final danmakuWeight = DanmakuOptions.danmakuWeight;
      var remaining = _maxDanmakuPerTick.clamp(
        0,
        _maxActiveDanmaku - _activeDanmakuCount(controller),
      );
      var remainingSpecial = _maxSpecialPerTick.clamp(
        0,
        _maxActiveSpecialDanmaku - controller.specialDanmaku.length,
      );
      if (remaining <= 0) return;
      final accepted = currentDanmakuList.length > remaining
          ? currentDanmakuList.where((e) => e.weight >= danmakuWeight).toList()
          : currentDanmakuList;
      final sampled = accepted.length > remaining
          ? List<DanmakuElem>.generate(
              remaining,
              (index) => accepted[index * accepted.length ~/ remaining],
              growable: false,
            )
          : accepted;
      for (final e in sampled) {
        if (e.weight < danmakuWeight) continue;
        if (remaining <= 0) break;
        bool added;
        if (e.mode == 7) {
          if (remainingSpecial <= 0) continue;
          try {
            final content = SpecialDanmakuContentItem.fromList(
              DmUtils.decimalToColor(e.color),
              e.fontsize.toDouble(),
              jsonDecode(e.content.replaceAll('\n', '\\n')),
              extra: VideoDanmaku(
                id: e.id.toInt(),
                mid: e.midHash,
                like: e.likeCount.toInt(),
              ),
            );
            if (!DanmakuRenderGuard.canRasterizeSpecial(
              content,
              MediaQuery.devicePixelRatioOf(context),
              controller.option.strokeWidth,
              controller.option.fontWeight,
            )) {
              continue;
            }
            added = controller.addDanmaku(content);
          } catch (_) {
            added = false;
          }
        } else {
          added = controller.addDanmaku(_normalContent(e));
        }
        if (added) {
          remaining--;
          if (e.mode == 7) remainingSpecial--;
        }
      }
    }
    _prepareBuffered(currentPosition);
  }

  DanmakuContentItem<DanmakuExtra> _normalContent(DanmakuElem element) =>
      DanmakuContentItem<DanmakuExtra>(
        element.content,
        color: DanmakuOptions.blockColorful
            ? Colors.white
            : DmUtils.decimalToColor(element.color),
        type: DmUtils.getPosition(element.mode),
        isColorful:
            playerController.showVipDanmaku &&
            element.colorful == DmColorfulType.VipGradualColor,
        count: element.count > 1 ? element.count : null,
        selfSend: element.isSelf,
        extra: VideoDanmaku(
          id: element.id.toInt(),
          mid: element.midHash,
          like: element.likeCount.toInt(),
        ),
      );

  void _prepareBuffered(int position) {
    final renderer = _windowsRenderer;
    if (renderer == null || (position - _lastPreparedPosition).abs() < 500) {
      return;
    }
    _lastPreparedPosition = position;
    final end = (position + 2000).clamp(
      position,
      (playerController.buffered.value * 1000).clamp(position, position + 2000),
    );
    if (end <= position + 100) return;
    renderer.queuePrewarm(
      _plDanmakuController
          .peekBufferedDanmaku(position + 100, end)
          .where(
            (element) =>
                element.mode != 7 &&
                element.weight >= DanmakuOptions.danmakuWeight,
          )
          .map(_normalContent),
    );
  }

  int _activeDanmakuCount(DanmakuController<DanmakuExtra> controller) {
    var count = controller.specialDanmaku.length;
    count += controller.staticDanmaku.nonNulls.length;
    for (final track in controller.scrollDanmaku) {
      count += track.length;
    }
    return count;
  }

  @override
  void dispose() {
    playerController
      ..removePositionListener(videoPositionListen)
      ..removeStatusLister(playerListener);
    _plDanmakuController.dispose();
    _controller = null;
    _windowsRenderer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final option = DanmakuOptions.get(
      notFullscreen: widget.notFullscreen,
      speed: playerController.playbackSpeed,
    );
    return Obx(
      () {
        final opacity = playerController.enableShowDanmaku.value
            ? playerController.danmakuOpacity.value
            : 0.0;
        if (PlatformUtils.isDesktop && _windowsPreprocess) {
          return WindowsDanmakuScreen<DanmakuExtra>(
            option: option,
            size: widget.size,
            opacity: opacity,
            createdRenderer: (renderer) {
              _windowsRenderer = renderer;
              playerController.danmakuController = _controller =
                  renderer.controller;
              if (!playerController.playerStatus.isPlaying) renderer.pause();
            },
          );
        }
        final child = DanmakuScreen<DanmakuExtra>(
          createdController: (e) {
            playerController.danmakuController = _controller = e;
          },
          option: option,
          size: widget.size,
        );
        if (opacity == 0) {
          // 关闭时不绘制弹幕，也暂停其 ticker；状态仍保留以便快速恢复。
          return TickerMode(
            enabled: false,
            child: Offstage(child: child),
          );
        }
        return AnimatedOpacity(
          opacity: opacity,
          duration: const Duration(milliseconds: 100),
          child: child,
        );
      },
    );
  }
}

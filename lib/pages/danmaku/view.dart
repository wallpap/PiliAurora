import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/controller.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/display_binding.dart';
import 'package:pili_aurora/pages/danmaku/echo_source.dart';
import 'package:pili_aurora/pages/danmaku/frame_rate_setting.dart';
import 'package:pili_aurora/pages/danmaku/merge.dart';
import 'package:pili_aurora/pages/danmaku/window_coordinator.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/danmaku/window_screen.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/utils/danmaku_options.dart';
import 'package:pili_aurora/utils/danmaku_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

/// 装配点播来源、媒体时钟与显示配置。
class PlDanmaku extends StatefulWidget {
  const PlDanmaku({
    super.key,
    required this.cid,
    required this.playerController,
    this.isPipMode = false,
    required this.isFullScreen,
    required this.isFileSource,
    required this.size,
  });
  final int cid;
  final PlPlayerController playerController;
  final bool isPipMode;
  final bool isFullScreen;
  final bool isFileSource;
  final Size size;
  bool get notFullscreen => !isFullScreen || isPipMode;

  @override
  State<PlDanmaku> createState() => _PlDanmakuState();
}

class _PlDanmakuState extends State<PlDanmaku> {
  PlPlayerController get player => widget.playerController;
  late PlDanmakuController _source;
  late DanmakuEchoSource _echoes;
  DanmakuWindowRenderer<DanmakuExtra>? _renderer;
  DanmakuWindowCoordinator<DanmakuExtra>? _coordinator;
  DanmakuDisplayBinding? _binding;
  StreamSubscription<BoxEvent>? _settings;
  bool _colorBlocked = DanmakuOptions.blockColorful;

  @override
  void initState() {
    super.initState();
    _createSource();
  }

  void _createSource() {
    _source = PlDanmakuController(widget.cid, player, widget.isFileSource);
    _echoes = DanmakuEchoSource(_source);
    player.addDanmakuRuleListener(_refreshRules);
    player.addDanmakuOptionsListener(_optionsChanged);
    _settings = GStorage.setting.watch().listen((event) {
      if ({
        SettingBoxKey.mergeDanmaku,
        SettingBoxKey.mergeDanmakuScale,
        SettingBoxKey.mergeDanmakuThreshold,
        SettingBoxKey.mergeDanmakuLogBase,
        SettingBoxKey.showVipDanmaku,
      }.contains(event.key)) {
        _refreshRules();
      }
    });
  }

  void _refreshRules() => unawaited(_source.refreshRules());

  void _optionsChanged() {
    if (_colorBlocked != DanmakuOptions.blockColorful) {
      _colorBlocked = DanmakuOptions.blockColorful;
      _refreshRules();
    }
    if (mounted) setState(() {});
  }

  void _configure() {
    final option = DanmakuOptions.get(notFullscreen: widget.notFullscreen);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final font = DefaultTextStyle.of(context).style.fontFamily;
    final renderer = _renderer;
    if (renderer != null) {
      if (TickerMode.valuesOf(context).enabled && !player.isLive) {
        player.danmakuDisplay = _binding;
      }
      renderer.requestConfiguration(
        option: option,
        size: widget.size,
        devicePixelRatio: dpr,
        fontFamily: font,
      );
      return;
    }
    final created = _renderer = DanmakuWindowRenderer<DanmakuExtra>(
      option: option,
      size: widget.size,
      devicePixelRatio: dpr,
      fontFamily: font,
    );
    _coordinator = DanmakuWindowCoordinator(
      source: _echoes,
      renderer: created,
      contentOf: _contentOf,
    );
    player.danmakuDisplay = _binding = DanmakuDisplayBinding(
      interaction: () => created.interaction,
      clear: () => created.reset(player.positionInMilliseconds * 1000),
      // 发送接口采用毫秒，投放时保留当前显示窗口的微秒下界。
      echo: (content, mediaUs) => _echoes.add(
        content,
        math.max(mediaUs, created.presentationTimeUs),
      ),
      seeking: created.suspendPresentation,
      remove: _echoes.remove,
    );
  }

  DanmakuContentItem<DanmakuExtra>? _contentOf(DanmakuElem element) {
    final echo = _echoes.contentFor(element);
    if (echo != null) return echo;
    if (!element.isSelf && element.weight < DanmakuOptions.danmakuWeight) {
      return null;
    }
    final extra = VideoDanmaku(
      id: element.id.toInt(),
      mid: element.midHash,
      like: element.likeCount.toInt(),
    );
    final color = DanmakuOptions.blockColorful
        ? Colors.white
        : DmUtils.decimalToColor(element.color);
    if (element.mode == 7) {
      try {
        return SpecialDanmakuContentItem<DanmakuExtra>.fromList(
          color,
          element.fontsize.toDouble(),
          jsonDecode(element.content.replaceAll('\n', r'\n')),
          extra: extra,
        );
      } catch (_) {
        return null;
      }
    }
    return DanmakuContentItem<DanmakuExtra>(
      element.content,
      color: color,
      type: DmUtils.getPosition(element.mode),
      isColorful:
          player.showVipDanmaku &&
          !DanmakuOptions.blockColorful &&
          element.colorful == DmColorfulType.VipGradualColor,
      count: element.count > 1 ? element.count : null,
      fontSizeScale: mergedDanmakuFontScale(
        element.count,
        enabled: player.mergeDanmaku && Pref.mergeDanmakuScale,
        threshold: Pref.mergeDanmakuThreshold,
        logBase: Pref.mergeDanmakuLogBase,
      ),
      selfSend: element.isSelf,
      extra: extra,
    );
  }

  @override
  void didUpdateWidget(PlDanmaku oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cid != widget.cid ||
        oldWidget.isFileSource != widget.isFileSource ||
        !identical(oldWidget.playerController, player)) {
      _release(oldWidget.playerController);
      _createSource();
    }
  }

  void _release(PlPlayerController owner) {
    owner
      ..removeDanmakuRuleListener(_refreshRules)
      ..removeDanmakuOptionsListener(_optionsChanged);
    if (identical(owner.danmakuDisplay, _binding)) owner.danmakuDisplay = null;
    unawaited(_settings?.cancel());
    _coordinator?.dispose();
    _renderer?.dispose();
    _echoes.dispose();
    _source.dispose();
    _renderer = null;
    _coordinator = null;
    _binding = null;
  }

  @override
  Widget build(BuildContext context) {
    _configure();
    final renderer = _renderer!;
    final coordinator = _coordinator!;
    return DanmakuFrameRateSetting(
      builder: (context, frameRate) => Obx(
        () => DanmakuWindowScreen<DanmakuExtra>(
          renderer: renderer,
          clock: player.mediaClock,
          size: widget.size,
          prepareFrame: coordinator.prepareFrame,
          needsPreparation: () => coordinator.needsPreparation,
          nextPreparationUs: () => coordinator.nextPreparationUs,
          inputChanges: coordinator.updates,
          opacity:
              player.enableShowDanmaku.value &&
                  (player.showDanmaku || widget.isPipMode)
              ? player.danmakuOpacity.value
              : 0,
          frameRate: frameRate,
          frameSource: player.frameSource,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _release(player);
    super.dispose();
  }
}

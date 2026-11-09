import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:math' as math;

import 'package:pili_aurora/common/widgets/dialog/simple_dialog_option.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/common/widgets/progress_bar/segment_progress_bar.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/sponsor_block.dart';
import 'package:pili_aurora/models/common/sponsor_block/segment_model.dart';
import 'package:pili_aurora/models/common/sponsor_block/action_type.dart';
import 'package:pili_aurora/models/common/sponsor_block/segment_type.dart';
import 'package:pili_aurora/models/common/sponsor_block/skip_type.dart';
import 'package:pili_aurora/models/remote/sponsor_block/segment_item.dart';
import 'package:pili_aurora/utils/duration_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/rate_limiter.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

mixin BlockConfigMixin {
  late final pgcSkipType = Pref.pgcSkipType;
  late final enablePgcSkip = pgcSkipType != SkipType.disable;
  late final enableSponsorBlock = Pref.enableSponsorBlock;
  late final enableBlock = enableSponsorBlock || enablePgcSkip;
  late final blockColor = Pref.blockColor;
  late final blockLimit = Pref.blockLimit * 1000;
  late final blockSettings = Pref.blockSettings;
  late final enableList = blockSettings
      .where((item) => item.second != SkipType.disable)
      .map((item) => item.first.name)
      .toSet();

  Color _getColor(SegmentType segment) => blockColor[segment.index];
}

mixin BlockMixin on GetxController {
  int? _lastBlockPos;
  int _blockGeneration = 0;
  bool _blockMuted = false;
  final _activeMuteSegments = <SegmentModel>{};
  final _manualVisits = <SegmentModel>{};
  final _pendingBlockVotes = <String>{};

  Future<void> applyBlockMute(bool muted);

  void _setBlockMuted(bool muted) {
    if (_blockMuted == muted) return;
    _blockMuted = muted;
    unawaited(
      Future<void>.sync(() => applyBlockMute(muted)).catchError(
        (Object error, StackTrace stackTrace) {
          logger.w(
            'failed to apply segment mute',
            error: error,
            stackTrace: stackTrace,
          );
        },
      ),
    );
  }

  void _updateMute(int position) {
    final active = <SegmentModel>{};
    for (final item in _segmentList) {
      if (item.actionType != ActionType.mute ||
          !item.segment.contains(position)) {
        continue;
      }
      if (item.skipType == SkipType.alwaysSkip ||
          (item.skipType == SkipType.skipOnce &&
              (!item.hasSkipped || _activeMuteSegments.contains(item)))) {
        active.add(item);
      }
    }
    for (final previous in _activeMuteSegments.difference(active)) {
      if (previous.skipType == SkipType.skipOnce) previous.hasSkipped = true;
    }
    _activeMuteSegments
      ..clear()
      ..addAll(active);
    _setBlockMuted(active.isNotEmpty);
  }

  BlockConfigMixin get blockConfig;
  StreamSubscription<Duration>? _blockListener;
  StreamSubscription<Duration>? get blockListener => _blockListener;
  late final List<SegmentModel> _segmentList = <SegmentModel>[];
  late final RxList<Segment> segmentProgressList = <Segment>[].obs;

  Timer? _skipTimer;
  late final listKey = GlobalKey<AnimatedListState>();
  late final List<Object> listData = [];

  RxString? get videoLabel => null;
  Player? get player;
  bool get autoPlay;
  int? get timeLength;
  bool get preInitPlayer;
  int get currPosInMilliseconds;
  bool get isFullScreen => false;

  bool get isUgc;
  late final isBlock = isUgc || !blockConfig.enablePgcSkip;

  Future<void> querySponsorBlock({
    required String bvid,
    required int cid,
    bool Function()? isCurrent,
  }) async {
    if (isClosed || !(isCurrent?.call() ?? true)) return;
    resetBlock();
    final generation = _blockGeneration;

    final result = await SponsorBlock.getSkipSegments(bvid: bvid, cid: cid);
    if (isClosed ||
        generation != _blockGeneration ||
        !(isCurrent?.call() ?? true)) {
      return;
    }
    switch (result) {
      case Success<List<SegmentItemModel>>(:final response):
        await handleSBData(response);
      case Error(:final code) when code != 404:
        if (kDebugMode) {
          result.toast();
        }
      default:
    }
  }

  void initSkip() {
    if (isClosed) return;
    if (_segmentList.isNotEmpty) {
      _blockListener?.cancel();
      final currentPlayer = player;
      if (currentPlayer == null) return;
      void handlePosition(Duration position) {
        // START_FILE 会先报告 playing；等待原生加载完成后再判断真实续播位置。
        if (currentPlayer.state.duration <= Duration.zero ||
            currentPlayer.state.buffering) {
          return;
        }
        if (isClosed || !identical(player, currentPlayer)) return;
        final msPos = position.inMilliseconds;
        _updateMute(msPos);
        _manualVisits.removeWhere((item) => !item.segment.contains(msPos));
        final currentPos = position.inSeconds;
        if (currentPos == _lastBlockPos) return;
        _lastBlockPos = currentPos;
        for (final item in _segmentList) {
          if (!item.segment.contains(msPos) ||
              item.actionType == ActionType.full ||
              item.actionType == ActionType.poi) {
            continue;
          }
          if (item.skipType == SkipType.skipManually) {
            if (_manualVisits.add(item)) onAddItem(item);
            continue;
          }
          // 静音按整个当前位置集合处理，重叠片段不会互相提前解除。
          if (item.actionType == ActionType.mute) continue;
          switch (item.skipType) {
            case SkipType.alwaysSkip:
              onSkip(item, isSeek: false);
              return;
            case SkipType.skipOnce:
              if (!item.hasSkipped) {
                item.hasSkipped = true;
                onSkip(item, isSeek: false);
                return;
              }
            default:
              break;
          }
        }
      }

      _blockListener = currentPlayer.stream.position.listen(handlePosition);
      if (autoPlay && currentPlayer.state.playing) {
        handlePosition(Duration(milliseconds: currPosInMilliseconds));
      }
    }
  }

  Future<void> handleSBData(List<SegmentItemModel> list) async {
    if (list.isNotEmpty) {
      try {
        final currentDuration = timeLength;
        final duration = currentDuration != null && currentDuration > 0
            ? currentDuration
            : list
                  .map((item) => item.videoDuration)
                  .whereType<num>()
                  .where((value) => value > 0)
                  .firstOrNull;
        if (duration == null) return;
        // segmentList
        _segmentList.addAll(
          list
              .where(
                (item) =>
                    blockConfig.enableList.contains(item.category) &&
                    item.effectiveActionType != null &&
                    item.segment.length == 2 &&
                    item.segment[0] >= 0 &&
                    item.segment[1] >= item.segment[0],
              )
              .map(
                (item) {
                  final segmentModel = SegmentModel.fromItemModel(
                    item,
                    isBlock ? blockConfig : null,
                  );
                  if (segmentModel.segment == const (0, 0)) {
                    videoLabel?.value +=
                        '${videoLabel!.value.isNotEmpty ? '/' : ''}${segmentModel.segmentType.title}';
                  }

                  return segmentModel;
                },
              ),
        );

        // _segmentProgressList
        segmentProgressList.addAll(
          _segmentList.map((e) {
            double start = (e.segment.$1 / duration).clamp(0.0, 1.0);
            double end = (e.segment.$2 / duration).clamp(0.0, 1.0);
            return Segment(
              start: start,
              end: end,
              color: blockConfig._getColor(e.segmentType),
            );
          }),
        );

        if (_blockListener == null && (autoPlay || preInitPlayer)) {
          initSkip();
        }
      } catch (e, stackTrace) {
        logger.w(
          'failed to parse sponsorblock: $e',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }
  }

  void onAddItem(Object item) {
    if (listData.contains(item)) return;
    listData.insert(0, item);
    listKey.currentState?.insertItem(0);
    _skipTimer ??= Timer.periodic(const Duration(seconds: 4), (_) {
      if (listData.isNotEmpty) {
        onRemoveItem(listData.length - 1, listData.last);
      }
    });
  }

  void onRemoveItem(int index, Object item) {
    ActionThrottle.run(
      'onRemoveItem',
      const Duration(milliseconds: 500),
      () {
        try {
          listData.removeAt(index);
          if (listData.isEmpty) {
            _stopSkipTimer();
          }
          listKey.currentState?.removeItem(
            index,
            (context, animation) => buildItem(item, animation),
          );
        } catch (_) {}
      },
    );
  }

  Widget buildItem(Object item, Animation<double> animation) =>
      throw UnimplementedError();

  void _stopSkipTimer() {
    if (_skipTimer != null) {
      _skipTimer!.cancel();
      _skipTimer = null;
    }
  }

  Future<void>? seekTo(Duration duration, {required bool isSeek});

  void _skipToast(SegmentModel item) {
    if (autoPlay && Pref.blockToast) {
      _showBlockToast('已跳过${item.segmentType.shortTitle}片段');
    }
    if (isBlock && Pref.blockTrack) {
      SponsorBlock.viewedVideoSponsorTime(item.uuid);
    }
  }

  Future<void> onSkip(
    SegmentModel item, {
    bool isSkip = true,
    bool isSeek = true,
  }) async {
    try {
      await seekTo(
        Duration(milliseconds: isSkip ? item.segment.$2 : item.segment.$1),
        isSeek: isSeek,
      );
      if (isSkip) {
        _skipToast(item);
      } else {
        _showBlockToast('已跳至${item.segmentType.shortTitle}');
      }
    } catch (e, stackTrace) {
      logger.w('failed to skip: $e', error: e, stackTrace: stackTrace);
      if (isSkip) {
        _showBlockToast('${item.segmentType.shortTitle}片段跳过失败');
      } else {
        _showBlockToast('跳转失败');
      }
    }
  }

  void _showBlockToast(String msg) {
    SmartDialog.showToast(
      msg,
      alignment: isFullScreen ? const Alignment(0, 0.7) : null,
    );
  }

  void _showVoteDialog(SegmentModel segment) {
    showDialog(
      context: Get.context!,
      builder: (context) => SimpleDialog(
        clipBehavior: .hardEdge,
        contentPadding: const .symmetric(vertical: 10),
        children: [
          DialogOption(
            child: const Text('赞成票', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              voteBlockSegment(uuid: segment.uuid, type: 1);
            },
          ),
          DialogOption(
            child: const Text('反对票', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              voteBlockSegment(uuid: segment.uuid, type: 0);
            },
          ),
          DialogOption(
            child: const Text('更改类别', style: TextStyle(fontSize: 14)),
            onPressed: () {
              Get.back();
              _showCategoryDialog(segment);
            },
          ),
        ],
      ),
    );
  }

  Future<void> voteBlockSegment({
    required String uuid,
    int? type,
    SegmentType? category,
  }) async {
    if (isClosed || !_pendingBlockVotes.add(uuid)) return;
    final generation = _blockGeneration;
    final server = Pref.blockServer;
    final userId = Pref.blockUserID;
    try {
      final result = await SponsorBlock.voteOnSponsorTime(
        uuid: uuid,
        type: type,
        category: category,
      );
      if (isClosed ||
          generation != _blockGeneration ||
          server != Pref.blockServer ||
          userId != Pref.blockUserID) {
        return;
      }
      if (result.isSuccess) {
        _showBlockToast(category == null ? '投票成功' : '类别更改成功');
      } else {
        result.toast();
      }
    } finally {
      _pendingBlockVotes.remove(uuid);
    }
  }

  void _showCategoryDialog(SegmentModel segment) {
    showDialog(
      context: Get.context!,
      builder: (context) => SimpleDialog(
        clipBehavior: .hardEdge,
        contentPadding: const .symmetric(vertical: 10),
        children: SegmentType.values
            .map(
              (item) => ListTile(
                dense: true,
                onTap: () {
                  Get.back();
                  voteBlockSegment(
                    uuid: segment.uuid,
                    category: item,
                  );
                },
                title: Text.rich(
                  TextSpan(
                    children: [
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Container(
                          height: 10,
                          width: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: blockConfig._getColor(item),
                          ),
                        ),
                        style: const TextStyle(fontSize: 14, height: 1),
                      ),
                      TextSpan(
                        text: ' ${item.title}',
                        style: const TextStyle(fontSize: 14, height: 1),
                      ),
                    ],
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  void showSBDetail() {
    showDialog(
      context: Get.context!,
      builder: (context) => SimpleDialog(
        clipBehavior: .hardEdge,
        contentPadding: const .symmetric(vertical: 10),
        children: _segmentList
            .map(
              (item) => ListTile(
                onTap: () {
                  Get.back();
                  if (isBlock) {
                    _showVoteDialog(item);
                  }
                },
                dense: true,
                title: Text.rich(
                  TextSpan(
                    children: [
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Container(
                          height: 10,
                          width: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: blockConfig._getColor(item.segmentType),
                          ),
                        ),
                        style: const TextStyle(fontSize: 14, height: 1),
                      ),
                      TextSpan(
                        text: ' ${item.segmentType.title}',
                        style: const TextStyle(fontSize: 14, height: 1),
                      ),
                    ],
                  ),
                ),
                contentPadding: const EdgeInsets.only(left: 16, right: 8),
                subtitle: Text(
                  '${DurationUtils.formatDuration(item.segment.$1 / 1000)} 至 ${DurationUtils.formatDuration(item.segment.$2 / 1000)}',
                  style: const TextStyle(fontSize: 13),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.behaviorLabel,
                      style: const TextStyle(fontSize: 13),
                    ),
                    if (item.segment.$2 != 0)
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton(
                          tooltip: item.skipType == SkipType.showOnly
                              ? '跳至此片段'
                              : '跳过此片段',
                          onPressed: () {
                            Get.back();
                            onSkip(
                              item,
                              isSkip: item.skipType != SkipType.showOnly,
                              isSeek: false,
                            );
                          },
                          style: IconButton.styleFrom(
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: Icon(
                            item.skipType == SkipType.showOnly
                                ? Icons.my_location
                                : MdiIcons.debugStepOver,
                            size: 18,
                            color: ColorScheme.of(
                              context,
                            ).onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 10),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  void cancelBlockListener() {
    _activeMuteSegments.clear();
    _setBlockMuted(false);
    if (_blockListener != null) {
      _blockListener!.cancel();
      _blockListener = null;
    }
  }

  void resetBlock() {
    _blockGeneration++;
    cancelBlockListener();
    _lastBlockPos = null;
    _manualVisits.clear();
    videoLabel?.value = '';
    _segmentList.clear();
    segmentProgressList.clear();
    // 切换来源时撤下旧片段操作，保留独立的历史分P提示。
    for (var index = listData.length - 1; index >= 0; index--) {
      if (listData[index] is! SegmentModel) continue;
      final item = listData.removeAt(index);
      listKey.currentState?.removeItem(
        index,
        (context, animation) => buildItem(item, animation),
      );
    }
    if (listData.isEmpty) _stopSkipTimer();
  }

  Duration? getFirstSegment([int pos = 0]) {
    for (var i in _segmentList..sort()) {
      if (i.actionType != ActionType.skip) continue;
      final (start, end) = i.segment;
      if (start == end) {
        continue;
      } else if (start - pos < 100) {
        if (switch (i.skipType) {
          .alwaysSkip => true,
          .skipOnce => !i.hasSkipped,
          _ => false,
        }) {
          if (i.skipType == SkipType.skipOnce) i.hasSkipped = true;
          _skipToast(i);
          pos = math.max(pos, i.segment.$2);
        }
      } else {
        break;
      }
    }
    if (pos != 0) {
      return Duration(milliseconds: pos);
    }
    return null;
  }

  @override
  void onClose() {
    _stopSkipTimer();
    if (blockConfig.enableBlock) {
      resetBlock();
    }
    super.onClose();
  }
}

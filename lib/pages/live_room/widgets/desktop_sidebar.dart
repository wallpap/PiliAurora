import 'dart:async';

import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/http/live.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/models/common/live/live_contribution_rank_type.dart';
import 'package:pili_aurora/models/remote/live/live_contribution_rank/item.dart';
import 'package:pili_aurora/models/remote/live/live_guard_top_list/data.dart';
import 'package:pili_aurora/models/remote/live/live_guard_top_list/item.dart';
import 'package:pili_aurora/pages/live_room/contribution_rank/controller.dart';
import 'package:pili_aurora/pages/live_room/widgets/live_list_sheet.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/pages/member_guard/view.dart';
import 'package:pili_aurora/utils/accounts.dart';

enum _SidebarTab { audience, guard }

class DesktopLiveSidebar extends StatefulWidget {
  const DesktopLiveSidebar({
    super.key,
    required this.roomId,
    required this.anchorUid,
    required this.anchorName,
    required this.liveRoomController,
    required this.chat,
    required this.input,
    required this.onShowRank,
  });

  final int roomId;
  final int? anchorUid;
  final String? anchorName;
  final LiveRoomController liveRoomController;
  final Widget chat;
  final Widget input;
  final VoidCallback onShowRank;

  @override
  State<DesktopLiveSidebar> createState() => _DesktopLiveSidebarState();
}

class _DesktopLiveSidebarState extends State<DesktopLiveSidebar> {
  _SidebarTab _tab = _SidebarTab.audience;
  ContributionRankController? _rankController;
  LoadingState<LiveGuardTopListData>? _guardState;
  int _guardGeneration = 0;

  String get _rankTag => 'desktop-live-${widget.roomId}';

  @override
  void initState() {
    super.initState();
    Accounts.mainChanges.addListener(_onAccountChanged);
    _ensureRankController();
  }

  @override
  void didUpdateWidget(covariant DesktopLiveSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomId != widget.roomId ||
        oldWidget.anchorUid != widget.anchorUid) {
      _deleteRankController(roomId: oldWidget.roomId);
      _rankController = null;
      _guardState = null;
      _guardGeneration++;
      _ensureRankController();
    }
  }

  void _ensureRankController() {
    final anchorUid = widget.anchorUid;
    if (anchorUid == null) return;
    _rankController =
        Get.isRegistered<ContributionRankController>(
          tag: _rankTag,
        )
        ? Get.find<ContributionRankController>(tag: _rankTag)
        : Get.put<ContributionRankController>(
            ContributionRankController(
              ruid: anchorUid,
              roomId: widget.roomId,
              type: LiveContributionRankType.online_rank,
            ),
            tag: _rankTag,
          );
    if (_guardState == null) {
      unawaited(_loadGuard());
    }
  }

  void _deleteRankController({int? roomId}) {
    final tag = 'desktop-live-${roomId ?? widget.roomId}';
    if (Get.isRegistered<ContributionRankController>(tag: tag)) {
      Get.delete<ContributionRankController>(tag: tag, force: true);
    }
  }

  void _onAccountChanged() => unawaited(_loadGuard());

  Future<void> _loadGuard() async {
    final anchorUid = widget.anchorUid;
    if (anchorUid == null) return;
    final account = Accounts.main;
    final generation = ++_guardGeneration;
    setState(() {
      _guardState = LoadingState<LiveGuardTopListData>.loading();
    });
    final state = await LiveHttp.liveGuardTopList(
      roomId: widget.roomId,
      ruid: anchorUid,
    );
    if (!mounted ||
        generation != _guardGeneration ||
        !identical(account, Accounts.main)) {
      return;
    }
    setState(() {
      _guardState = state;
    });
  }

  @override
  void dispose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    _guardGeneration++;
    _deleteRankController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xF216171A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTabs(context),
          _buildPreview(context),
          _buildChatHead(context),
          Expanded(child: widget.chat),
          widget.input,
        ],
      ),
    );
  }

  Widget _buildTabs(BuildContext context) {
    return Obx(
      () => SizedBox(
        height: 54,
        child: Row(
          children: [
            Expanded(
              child: _SidebarTabButton(
                label: '房间观众',
                count: widget.liveRoomController.onlineCount.value,
                selected: _tab == _SidebarTab.audience,
                onTap: () {
                  if (_tab != _SidebarTab.audience) {
                    setState(() => _tab = _SidebarTab.audience);
                  }
                },
              ),
            ),
            Expanded(
              child: _SidebarTabButton(
                label: '大航海',
                count: _guardState?.dataOrNull?.count?.toString(),
                selected: _tab == _SidebarTab.guard,
                onTap: () {
                  if (_tab != _SidebarTab.guard) {
                    setState(() => _tab = _SidebarTab.guard);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final isAudience = _tab == _SidebarTab.audience;
    return SizedBox(
      height: 148,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Column(
          children: [
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  Text(
                    isAudience ? '在线榜' : '舰长榜',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFC5C7CD),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      isAudience ? '投喂、点赞、发弹幕均可上榜' : '按舰长榜展示前三名',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF7E8189),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _openAll(isAudience),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF8F929A),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(88, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('查看全部', style: TextStyle(fontSize: 12)),
                        Icon(Icons.chevron_right, size: 14),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 3),
            Expanded(
              child: isAudience
                  ? _buildAudiencePreview(context)
                  : _buildGuardPreview(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudiencePreview(BuildContext context) {
    final controller = _rankController;
    if (controller == null) {
      return const _SidebarPreviewMessage(message: '等待直播间信息');
    }
    return Obx(() {
      return switch (controller.loadingState.value) {
        Loading() => const _SidebarPreviewLoading(),
        Success(:final response) => _buildAudienceCards(
          context,
          response ?? const [],
        ),
        Error(:final errMsg) => _SidebarPreviewMessage(
          message: errMsg ?? '在线榜加载失败',
          onRetry: controller.onReload,
        ),
      };
    });
  }

  Widget _buildGuardPreview(BuildContext context) {
    return switch (_guardState) {
      null || Loading() => const _SidebarPreviewLoading(),
      Success(:final response) => _buildGuardCards(context, response.tops),
      Error(:final errMsg) => _SidebarPreviewMessage(
        message: errMsg ?? '大航海加载失败',
        onRetry: _loadGuard,
      ),
    };
  }

  Widget _buildAudienceCards(
    BuildContext context,
    List<LiveContributionRankItem> items,
  ) {
    final values = List<LiveContributionRankItem?>.generate(
      3,
      (index) => items.elementAtOrNull(index),
    );
    return Row(
      children: [
        for (final (index, item) in values.indexed) ...[
          if (index > 0) const SizedBox(width: 7),
          Expanded(
            child: _RankPreviewCard(
              rank: index + 1,
              score: item?.score?.toString(),
              name: item?.name,
              face: item?.face,
              meta: item?.uinfoMedal == null
                  ? null
                  : '${item!.uinfoMedal!.name ?? ''} ${item.uinfoMedal!.level ?? ''}',
              onTap: item?.uid == null ? null : () => _openMember(item!.uid),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildGuardCards(
    BuildContext context,
    List<LiveGuardTopListItem> items,
  ) {
    final values = List<LiveGuardTopListItem?>.generate(
      3,
      (index) => items.elementAtOrNull(index),
    );
    return Row(
      children: [
        for (final (index, item) in values.indexed) ...[
          if (index > 0) const SizedBox(width: 7),
          Expanded(
            child: _RankPreviewCard(
              rank: index + 1,
              score: item?.accompany == null ? null : '${item!.accompany}天',
              name: item?.username,
              face: item?.face,
              meta: item?.medalName == null
                  ? null
                  : '${item!.medalName} ${item.medalLevel ?? ''}',
              onTap: item?.uid == null ? null : () => _openMember(item!.uid),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildChatHead(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFF292A2F)),
          bottom: BorderSide(color: Color(0xFF292A2F)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(
              color: Color(0xFF5CCF9B),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          const Text(
            '实时聊天',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFFD9DADD),
            ),
          ),
          const SizedBox(width: 7),
          Obx(
            () => Text(
              '${widget.liveRoomController.messages.value.length} 条',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF72757D),
              ),
            ),
          ),
          const Spacer(),
          const Text(
            '最新消息在底部',
            style: TextStyle(fontSize: 12, color: Color(0xFF888B93)),
          ),
        ],
      ),
    );
  }

  void _openMember(int? uid) {
    if (uid == null) return;
    Get.toNamed('/member?mid=$uid');
  }

  void _openAll(bool isAudience) {
    if (isAudience) {
      widget.onShowRank();
      return;
    }
    final anchorUid = widget.anchorUid;
    if (anchorUid == null) return;
    final count = _guardState?.dataOrNull?.count;
    showLiveListSheet(
      context: context,
      title:
          '${widget.anchorName ?? '主播'}的舰队${count == null ? '' : '($count)'}',
      child: MemberGuard.panel(ruid: anchorUid),
    );
  }
}

class _SidebarTabButton extends StatelessWidget {
  const _SidebarTabButton({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? const Color(0xFFF1F2F4) : const Color(0xFF8F929A);
    return InkWell(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          Center(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (count != null)
                    TextSpan(
                      text: '  $count',
                      style: TextStyle(
                        color: selected
                            ? const Color(0xFFC5C7CD)
                            : const Color(0xFF777A82),
                      ),
                    ),
                ],
              ),
              style: TextStyle(fontSize: 15, color: color),
            ),
          ),
          if (selected)
            Positioned(
              bottom: 0,
              child: Container(
                width: 28,
                height: 2,
                decoration: BoxDecoration(
                  color: ColorScheme.of(context).primary,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RankPreviewCard extends StatelessWidget {
  const _RankPreviewCard({
    required this.rank,
    required this.score,
    required this.name,
    required this.face,
    required this.meta,
    required this.onTap,
  });

  final int rank;
  final String? score;
  final String? name;
  final String? face;
  final String? meta;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isTop = rank == 1;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: isTop ? const Color(0xFF2D2820) : const Color(0xFF202126),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: const Color(0xFFE4A8B1),
                    ),
                    child: Text(
                      '$rank',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF652D35),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    score ?? '--',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12,
                      color: isTop
                          ? const Color(0xFFDFC17B)
                          : const Color(0xFFB6B8BF),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  NetworkImgLayer(
                    src: face,
                    width: 24,
                    height: 24,
                    type: ImageType.avatar,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      name ?? '暂无',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFE7E8EC),
                      ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                meta ?? ' ',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF84878F),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarPreviewLoading extends StatelessWidget {
  const _SidebarPreviewLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

class _SidebarPreviewMessage extends StatelessWidget {
  const _SidebarPreviewMessage({
    required this.message,
    this.onRetry,
  });

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF85878E)),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 24),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('重试', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

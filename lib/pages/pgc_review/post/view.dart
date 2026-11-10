import 'package:pili_aurora/common/widgets/custom_icon.dart';
import 'package:pili_aurora/common/widgets/view_insets_safe_area.dart';
import 'package:pili_aurora/http/pgc.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class PgcReviewPostPanel extends StatefulWidget {
  const PgcReviewPostPanel({
    super.key,
    required this.name,
    required this.mediaId,
    this.reviewId,
    this.score,
    this.content,
  });

  final String name;
  final Object? mediaId;
  // modify
  final Object? reviewId;
  final int? score;
  final String? content;

  @override
  State<PgcReviewPostPanel> createState() => _PgcReviewPostPanelState();
}

class _PgcReviewPostPanelState extends State<PgcReviewPostPanel> {
  late final TextEditingController _controller;
  late final RxInt _score = (widget.score ?? 0).obs;
  late final RxBool _shareFeed = false.obs;
  late final RxBool _enablePost = _isMod.obs;
  late final _isMod = widget.reviewId != null;
  final _posting = false.obs;
  final _account = Accounts.main;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.content);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onScore(double dx) {
    int index = (dx ~/ 50).clamp(0, 4);
    _enablePost.value = true;
    _score.value = index + 1;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 45,
          child: AppBar(
            backgroundColor: Colors.transparent,
            automaticallyImplyLeading: false,
            titleSpacing: 16,
            toolbarHeight: 45,
            title: Text(widget.name),
            actions: [
              IconButton(
                icon: const Icon(Icons.clear, size: 20),
                onPressed: Get.back,
              ),
              const SizedBox(width: 2),
            ],
            shape: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.1),
              ),
            ),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 8),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) =>
                  _onScore(details.localPosition.dx),
              onTapDown: (details) => _onScore(details.localPosition.dx),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(
                  5,
                  (index) {
                    return Obx(
                      () => index <= _score.value - 1
                          ? const Icon(
                              CustomIcons.star_favorite_solid,
                              size: 50,
                              color: Color(0xFFFFAD35),
                            )
                          : const Icon(
                              CustomIcons.star_favorite_line,
                              size: 50,
                              color: Colors.grey,
                            ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        Center(
          child: Obx(
            () {
              final score = _score.value;
              return Text(
                switch (score) {
                  1 => '很差',
                  2 => '较差',
                  3 => '还行',
                  4 => '很好',
                  5 => '佳作',
                  _ => '轻触评分',
                },
                style: TextStyle(
                  fontSize: 16,
                  color: score == 0
                      ? theme.colorScheme.outline
                      : const Color(0xFFFFAD35),
                ),
              );
            },
          ),
        ),
        Flexible(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              maxLength: 100,
              minLines: 5,
              maxLines: 5,
              controller: _controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
            ),
          ),
        ),
        if (!_isMod)
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
            child: GestureDetector(
              behavior: .opaque,
              onTap: _shareFeed.toggle,
              child: Obx(
                () {
                  final shareFeed = _shareFeed.value;
                  Color color = shareFeed
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline;
                  return Row(
                    mainAxisSize: .min,
                    children: [
                      Icon(
                        size: 22,
                        shareFeed
                            ? Icons.check_box_outlined
                            : Icons.check_box_outline_blank_outlined,
                        color: color,
                      ),
                      Text(' 分享到动态', style: TextStyle(color: color)),
                    ],
                  );
                },
              ),
            ),
          ),
        ViewInsetsSafeArea(
          child: Container(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 6,
              bottom: MediaQuery.paddingOf(context).bottom + 6,
            ),
            width: double.infinity,
            decoration: BoxDecoration(
              color: theme.colorScheme.onInverseSurface,
              border: Border(
                top: BorderSide(
                  width: 0.5,
                  color: theme.colorScheme.outline.withValues(alpha: 0.1),
                ),
              ),
            ),
            child: Obx(
              () => FilledButton.tonal(
                style: FilledButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: EdgeInsets.zero,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(6)),
                  ),
                ),
                onPressed: _enablePost.value && !_posting.value
                    ? _onPost
                    : null,
                child: Text(
                  _posting.value
                      ? '提交中…'
                      : _isMod
                      ? '编辑'
                      : '发布',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onPost() async {
    if (_posting.value) return;
    final account = _account;
    if (!identical(account, Accounts.main)) {
      SmartDialog.showToast('账号已切换，请重新打开点评面板');
      return;
    }
    if (!account.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final mediaId = widget.mediaId;
    final reviewId = widget.reviewId;
    final score = _score.value;
    final content = _controller.text;
    final shareFeed = _shareFeed.value;
    if (score < 1 || score > 5) {
      SmartDialog.showToast('请先选择评分');
      return;
    }
    final route = ModalRoute.of(context);
    _posting.value = true;
    try {
      final res = _isMod
          ? await PgcHttp.pgcReviewMod(
              mediaId: mediaId,
              score: score * 2,
              content: content,
              reviewId: reviewId,
              account: account,
            )
          : await PgcHttp.pgcReviewPost(
              mediaId: mediaId,
              score: score * 2,
              content: content,
              shareFeed: shareFeed,
              account: account,
            );
      if (!mounted ||
          route?.isCurrent == false ||
          !identical(account, Accounts.main) ||
          mediaId != widget.mediaId ||
          reviewId != widget.reviewId) {
        return;
      }
      if (res.isSuccess) {
        final unchanged =
            content == _controller.text &&
            score == _score.value &&
            shareFeed == _shareFeed.value;
        if (unchanged) Navigator.of(context).pop();
        SmartDialog.showToast(
          unchanged
              ? _isMod
                    ? '编辑成功'
                    : '点评成功'
              : '提交成功，已保留新草稿',
        );
      } else {
        res.toast();
      }
    } finally {
      _posting.value = false;
    }
  }
}

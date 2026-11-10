import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/home/rcmd/result.dart';
import 'package:pili_aurora/models/model_video.dart';
import 'package:pili_aurora/pages/search/widgets/search_text.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

class VideoFeedbackDialog extends StatefulWidget {
  const VideoFeedbackDialog({
    super.key,
    required this.item,
    required this.isCurrent,
    this.onRemove,
  });

  final BaseSimpleVideoItemModel item;
  final bool Function() isCurrent;
  final VoidCallback? onRemove;

  @override
  State<VideoFeedbackDialog> createState() => _VideoFeedbackDialogState();
}

class _VideoFeedbackDialogState extends State<VideoFeedbackDialog> {
  late final Account _account;

  @override
  void initState() {
    super.initState();
    _account = widget.item is RcmdVideoItemAppModel
        ? Accounts.get(.recommend)
        : Accounts.main;
  }

  bool _pending = false;

  bool get _current =>
      mounted &&
      widget.isCurrent() &&
      identical(
        _account,
        widget.item is RcmdVideoItemAppModel
            ? Accounts.get(.recommend)
            : Accounts.main,
      );

  Object? get _targetKey => switch (widget.item) {
    RcmdVideoItemAppModel item => (item.goto, item.param),
    final item => item.bvid,
  };

  Future<void> _submit({
    Reason? reason,
    Reason? feedback,
    bool cancel = false,
  }) async {
    if (_pending || !_current) return;
    final item = widget.item;
    final targetKey = _targetKey;
    final route = ModalRoute.of(context);
    setState(() => _pending = true);
    try {
      final LoadingState<void> result;
      if (item is RcmdVideoItemAppModel) {
        final id = item.param;
        final target = item.goto;
        if (id == null || target == null) {
          SmartDialog.showToast('推荐反馈信息不完整，请刷新后重试');
          return;
        }
        result = cancel
            ? await VideoHttp.feedDislikeCancel(
                id: id,
                goto: target,
                account: _account,
              )
            : await VideoHttp.feedDislike(
                id: id,
                goto: target,
                reasonId: reason?.id,
                feedbackId: feedback?.id,
                account: _account,
              );
      } else {
        result = await VideoHttp.dislikeVideo(
          bvid: item.bvid ?? '',
          type: !cancel,
          account: _account,
        );
      }
      if (!mounted ||
          !_current ||
          route?.isCurrent == false ||
          !identical(item, widget.item) ||
          targetKey != _targetKey) {
        return;
      }
      if (result.isSuccess) {
        Navigator.of(context).pop();
        SmartDialog.showToast(
          cancel ? '已撤销反馈' : reason?.toast ?? feedback?.toast ?? '反馈成功',
        );
        if (!cancel) {
          try {
            widget.onRemove?.call();
          } catch (error, stackTrace) {
            // 页面刷新失败不能改写已经确认的反馈结果。
            logger.w(
              '反馈已成功，更新视频列表失败',
              error: error.runtimeType,
              stackTrace: stackTrace,
            );
          }
        }
      } else {
        result.toast();
      }
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final points = item is RcmdVideoItemAppModel ? item.threePoint : null;
    final reasons =
        points?.dislikeReasons?.where((reason) => reason.id != null).toList() ??
        [];
    final feedbacks =
        points?.feedbacks?.where((reason) => reason.id != null).toList() ?? [];
    Widget choices(List<Reason> values, {bool feedback = false}) => Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          SearchText(
            text: value.name ?? '其他原因',
            onTap: (_) => _submit(
              reason: feedback ? null : value,
              feedback: feedback ? value : null,
            ),
          ),
      ],
    );
    return SimpleDialog(
      contentPadding: const .fromLTRB(24, 16, 24, 24),
      children: [
        if (_pending)
          const Padding(
            padding: .only(bottom: 12),
            child: Text('提交中…', textAlign: .center),
          ),
        if (item is RcmdVideoItemAppModel) ...[
          if (reasons.isEmpty && feedbacks.isEmpty)
            const Text('推荐反馈信息不完整，请刷新列表后重试'),
          IgnorePointer(
            ignoring: _pending,
            child: Column(
              crossAxisAlignment: .start,
              children: [
                if (reasons.isNotEmpty) ...[
                  const Text('我不想看'),
                  const SizedBox(height: 5),
                  choices(reasons),
                ],
                if (feedbacks.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  const Text('反馈'),
                  const SizedBox(height: 5),
                  choices(feedbacks, feedback: true),
                ],
              ],
            ),
          ),
        ] else ...[
          const Text('web端暂不支持精细选择', textAlign: .center),
          const SizedBox(height: 5),
          FilledButton.tonal(
            onPressed: _pending ? null : _submit,
            child: const Text('点踩'),
          ),
        ],
        const Divider(),
        FilledButton.tonal(
          onPressed: _pending ? null : () => _submit(cancel: true),
          child: const Text('撤销'),
        ),
      ],
    );
  }
}

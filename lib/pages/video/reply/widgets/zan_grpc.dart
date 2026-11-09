import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:pili_aurora/http/reply.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/feed_back.dart';
import 'package:pili_aurora/utils/num_utils.dart';
import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:material_ui/material_ui.dart';

class ZanButtonGrpc extends StatefulWidget {
  const ZanButtonGrpc({
    super.key,
    required this.replyItem,
    this.onUpdate,
  });

  final ReplyInfo replyItem;
  final VoidCallback? onUpdate;

  @override
  State<ZanButtonGrpc> createState() => _ZanButtonGrpcState();
}

class _ZanButtonGrpcState extends State<ZanButtonGrpc> {
  bool _processing = false;

  Future<void> _react({required bool like}) async {
    if (_processing) return;
    final account = Accounts.main;
    if (!account.isLogin) {
      SmartDialog.showToast('请先登录');
      return;
    }
    final item = widget.replyItem;
    final previous = item.replyControl.action;
    final action = (like ? $fixnum.Int64.ONE : $fixnum.Int64.TWO) == previous
        ? $fixnum.Int64.ZERO
        : like
        ? $fixnum.Int64.ONE
        : $fixnum.Int64.TWO;
    setState(() => _processing = true);
    feedBack();
    try {
      final invoke = like ? ReplyHttp.likeReply : ReplyHttp.hateReply;
      final result = await invoke(
        account: account,
        type: item.type.toInt(),
        oid: item.oid.toInt(),
        rpid: item.id.toInt(),
        action: action == $fixnum.Int64.ZERO ? 0 : 1,
      );
      if (!mounted ||
          !identical(account, Accounts.main) ||
          !identical(item, widget.replyItem)) {
        return;
      }
      if (result.isSuccess) {
        setState(() {
          if (previous == $fixnum.Int64.ONE) item.like -= $fixnum.Int64.ONE;
          if (action == $fixnum.Int64.ONE) item.like += $fixnum.Int64.ONE;
          item.ensureReplyControl().action = action;
        });
        SmartDialog.showToast(
          action == $fixnum.Int64.ZERO
              ? (like ? '取消赞' : '取消踩')
              : (like ? '点赞成功' : '点踩成功'),
        );
        widget.onUpdate?.call();
      } else {
        result.toast();
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final action = widget.replyItem.replyControl.action;
    final isLike = action == $fixnum.Int64.ONE;
    final isDislike = action == $fixnum.Int64.TWO;
    final outline = theme.colorScheme.outline;
    final primary = theme.colorScheme.primary;
    final ButtonStyle style = TextButton.styleFrom(
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 32,
          child: TextButton(
            style: const ButtonStyle(
              visualDensity: .compact,
              tapTargetSize: .shrinkWrap,
              padding: WidgetStatePropertyAll(.zero),
              minimumSize: WidgetStatePropertyAll(.square(40)),
            ),
            onPressed: _processing ? null : () => _react(like: false),
            child: Icon(
              isDislike
                  ? FontAwesomeIcons.solidThumbsDown.data
                  : FontAwesomeIcons.thumbsDown.data,
              size: 16,
              color: isDislike ? primary : outline,
              semanticLabel: isDislike ? '已踩' : '点踩',
            ),
          ),
        ),
        SizedBox(
          height: 32,
          child: TextButton(
            style: style,
            onPressed: _processing ? null : () => _react(like: true),
            child: Row(
              spacing: 4,
              children: [
                Icon(
                  isLike
                      ? FontAwesomeIcons.solidThumbsUp.data
                      : FontAwesomeIcons.thumbsUp.data,
                  size: 16,
                  color: isLike ? primary : outline,
                  semanticLabel: isLike ? '已赞' : '点赞',
                ),
                Text(
                  NumUtils.numFormat(widget.replyItem.like.toInt()),
                  style: TextStyle(
                    color: isLike ? primary : outline,
                    fontSize: theme.textTheme.labelSmall!.fontSize,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

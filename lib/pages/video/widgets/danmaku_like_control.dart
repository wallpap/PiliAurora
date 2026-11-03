import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/danmaku.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

/// 用户点赞状态不在弹幕分段中，按需在操作入口查询。
class DanmakuLikeControl extends StatefulWidget {
  const DanmakuLikeControl({
    super.key,
    required this.extra,
    required this.cid,
    required this.onLike,
    required this.builder,
  });

  final VideoDanmaku extra;
  final int cid;
  final Future<void> Function() onLike;
  final Widget Function(BuildContext, Future<void> Function()) builder;

  @override
  State<DanmakuLikeControl> createState() => _DanmakuLikeControlState();
}

class _DanmakuLikeControlState extends State<DanmakuLikeControl> {
  late Account _account;
  bool _busy = false;
  bool _loaded = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(DanmakuLikeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.extra, oldWidget.extra) ||
        widget.cid != oldWidget.cid ||
        !identical(_account, Accounts.main)) {
      _refresh();
    }
  }

  Future<bool> _refresh({bool toast = false}) async {
    final generation = ++_generation;
    final extra = widget.extra;
    _account = Accounts.main;
    _loaded = false;
    if (!_account.isLogin) {
      extra.isLike = false;
      _busy = false;
      return true;
    }
    _busy = true;
    try {
      final result = await DanmakuHttp.likeStats(
        cid: widget.cid,
        id: extra.id,
        account: _account,
      );
      // 切换弹幕、视频或账号后的迟到结果不能写回当前菜单。
      if (!mounted ||
          generation != _generation ||
          !identical(_account, Accounts.main)) {
        return false;
      }
      if (result case Success(:final response)) {
        extra
          ..isLike = response.isLike
          ..like = response.likes;
        _loaded = true;
      } else if (toast) {
        result.toast();
      }
      return _loaded;
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _toggle() async {
    if (_busy) return;
    if (!_loaded || !identical(_account, Accounts.main)) {
      setState(() => _busy = true);
      if (!await _refresh(toast: true) || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      await widget.onLike();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: _busy,
    child: widget.builder(context, _toggle),
  );
}

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
    this.placeholderSize = const Size.square(36),
    this.placeholderColor,
  });

  final VideoDanmaku extra;
  final int cid;
  final Future<void> Function() onLike;
  final Widget Function(BuildContext, Future<void> Function()) builder;
  final Size placeholderSize;
  final Color? placeholderColor;

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
      _loaded = true;
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
    } catch (_) {
      if (mounted &&
          generation == _generation &&
          identical(_account, Accounts.main) &&
          toast) {
        const Error('未能获取弹幕点赞状态，请重试').toast();
      }
      return false;
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

  Future<void> _retry() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _refresh(toast: true);
  }

  @override
  Widget build(BuildContext context) {
    // 分段里的默认 false 不代表当前账号未点赞，查询完成前不构建点赞按钮。
    if (!_loaded) {
      return SizedBox.fromSize(
        size: widget.placeholderSize,
        child: Center(
          child: _busy
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: widget.placeholderColor,
                    semanticsLabel: '正在获取弹幕点赞状态',
                  ),
                )
              : IconButton(
                  tooltip: '重新获取弹幕点赞状态',
                  onPressed: _retry,
                  padding: EdgeInsets.zero,
                  iconSize: 20,
                  color: widget.placeholderColor,
                  icon: const Icon(Icons.refresh),
                ),
        ),
      );
    }
    return IgnorePointer(
      ignoring: _busy,
      child: widget.builder(context, _toggle),
    );
  }
}

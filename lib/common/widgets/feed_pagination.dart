import 'dart:async';

import 'package:flutter/widgets.dart';

/// 按实际滚动范围分页，避免预加载区构建末项时连续请求。
class FeedPagination extends StatefulWidget {
  const FeedPagination({
    super.key,
    required this.controller,
    this.dataChanges,
    this.dataRevision,
    this.dataSource,
    required this.canLoadMore,
    required this.onLoadMore,
    required this.child,
    this.prefetchExtent,
  });

  final ScrollController controller;
  final Stream<Object?>? dataChanges;

  /// 由父节点订阅快照的页面通过修订值触发检查，无需再桥接一条 stream。
  final Object? dataRevision;

  /// 查询所有者变更时释放旧请求的分页占位；比较对象身份。
  final Object? dataSource;
  final bool Function() canLoadMore;
  final Future<void> Function() onLoadMore;
  final Widget child;

  /// 用户滚动后的预取距离，由页面按实际卡片行高计算。
  final double Function()? prefetchExtent;

  @override
  State<FeedPagination> createState() => _FeedPaginationState();
}

class _FeedPaginationState extends State<FeedPagination> {
  bool _scheduled = false;
  int _generation = 0;
  int? _loadingGeneration;
  StreamSubscription<Object?>? _subscription;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_schedule);
    _subscription = widget.dataChanges?.listen((_) => _schedule());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(FeedPagination oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = widget.controller != oldWidget.controller;
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(_schedule);
      widget.controller.addListener(_schedule);
    }
    if (widget.dataChanges != oldWidget.dataChanges) {
      _subscription?.cancel();
      _subscription = widget.dataChanges?.listen((_) => _schedule());
    }
    if (changed || !identical(widget.dataSource, oldWidget.dataSource)) {
      // 控制器或显式所有者标识列表归属；Rx.stream 的新包装不能作为代次。
      // 新列表不继承旧请求；旧完成也不能释放新列表的加载标记。
      _generation++;
      _schedule();
    }
    if (widget.dataRevision != oldWidget.dataRevision) _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_check());
    });
  }

  Future<void> _check() async {
    if (_loadingGeneration == _generation ||
        !TickerMode.valuesOf(context).enabled ||
        widget.controller.positions.length != 1 ||
        !widget.canLoadMore()) {
      return;
    }
    final position = widget.controller.position;
    if (!position.hasContentDimensions || position.viewportDimension <= 0) {
      return;
    }
    // 首屏补足可视区；滚动时按页面指定的余量预取，留出网络加载时间。
    final threshold = position.pixels > position.minScrollExtent
        ? (widget.prefetchExtent?.call() ?? position.viewportDimension / 4)
        : 0.0;
    if (position.extentAfter > threshold) return;
    final extent = position.maxScrollExtent;
    final generation = _generation;
    _loadingGeneration = generation;
    try {
      await widget.onLoadMore();
    } finally {
      if (_loadingGeneration == generation) _loadingGeneration = null;
    }
    // 无增长（错误或终点）不自行重试，增长后的布局由 metrics 通知检查。
    if (mounted &&
        generation == _generation &&
        position.hasPixels &&
        position.maxScrollExtent != extent) {
      _schedule();
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical) {
          _schedule();
        }
        return false;
      },
      child: widget.child,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    widget.controller.removeListener(_schedule);
    super.dispose();
  }
}

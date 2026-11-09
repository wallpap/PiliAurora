import 'package:pili_aurora/common/widgets/reorder_mixin.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/fav/fav_detail/media.dart';
import 'package:pili_aurora/pages/fav_detail/controller.dart';
import 'package:pili_aurora/pages/fav_detail/widget/fav_video_card.dart';
import 'package:pili_aurora/utils/extension/iterable_ext.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

class FavSortPage extends StatefulWidget {
  const FavSortPage({super.key, required this.favDetailController});

  final FavDetailController favDetailController;

  @override
  State<FavSortPage> createState() => _FavSortPageState();
}

class _FavSortPageState extends State<FavSortPage> with ReorderMixin {
  FavDetailController get _favDetailController => widget.favDetailController;

  late final _account = _favDetailController.account;
  late final _folder = _favDetailController.mediaId;
  late final _source = _favDetailController.loadingState.value.dataOrNull;
  late var _original = List<FavDetailItemModel>.of(_source ?? []);
  late final sortList = List<FavDetailItemModel>.of(_original);
  List<String> sort = <String>[];
  bool _loading = false;
  bool _saving = false;

  bool get _current =>
      mounted &&
      _favDetailController.isFavCurrent &&
      identical(_account, Accounts.main) &&
      _folder == _favDetailController.mediaId &&
      identical(_source, _favDetailController.loadingState.value.dataOrNull);

  Future<void> onLoadMore() async {
    if (_loading || _saving || !_current || _favDetailController.isEnd) return;
    _loading = true;
    try {
      await _favDetailController.onLoadMore();
      if (!_current ||
          _source == null ||
          !listEquals(_original, _source.take(_original.length).toList())) {
        return;
      }
      sortList.addAll(_source.skip(_original.length));
      _original = List.of(_source);
      setState(() {});
    } finally {
      _loading = false;
    }
  }

  Future<void> _save() async {
    if (_saving || _loading) return;
    if (!_current || !listEquals(_original, _source)) {
      SmartDialog.showToast('收藏列表已更新，请重新打开排序');
      return;
    }
    if (sort.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await FavHttp.sortFav(
        account: _account,
        mediaId: _folder,
        sort: sort.join(','),
      );
      if (!mounted || !_current || !listEquals(_original, _source)) return;
      if (result.isSuccess) {
        _favDetailController.loadingState.value = Success(List.of(sortList));
        SmartDialog.showToast('排序完成');
        if (ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop();
        }
      } else {
        result.toast();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(
        title: Text('排序: ${_favDetailController.folderInfo.value.title}'),
        actions: [
          TextButton(
            onPressed: _saving || _loading ? null : _save,
            child: const Text('完成'),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: _buildBody,
    );
  }

  void onReorderItem(int oldIndex, int newIndex) {
    if (_saving || _loading || !_current) return;
    final oldItem = sortList[oldIndex];
    final newItem = sortList.getOrNull(
      oldIndex > newIndex ? newIndex - 1 : newIndex, // might be Negative
    );
    sort.add(
      '${newItem == null ? '0:0' : '${newItem.id}:${newItem.type}'}:${oldItem.id}:${oldItem.type}',
    );

    sortList.insert(newIndex, sortList.removeAt(oldIndex));

    setState(() {});
  }

  Widget get _buildBody {
    final child = ReorderableListView.builder(
      onReorderItem: onReorderItem,
      proxyDecorator: proxyDecorator,
      physics: const AlwaysScrollableScrollPhysics(),
      padding:
          MediaQuery.viewPaddingOf(context).copyWith(top: 0) +
          const EdgeInsets.only(bottom: 100),
      itemCount: sortList.length,
      itemBuilder: (context, index) {
        final item = sortList[index];
        return SizedBox(
          key: ValueKey(item.id),
          height: 110,
          child: FavVideoCardH(item: item),
        );
      },
    );
    if (!_favDetailController.isEnd) {
      return NotificationListener<ScrollEndNotification>(
        onNotification: (notification) {
          final metrics = notification.metrics;
          if (metrics.pixels >= metrics.maxScrollExtent - 300) {
            onLoadMore();
          }
          return false;
        },
        child: child,
      );
    }
    return child;
  }
}

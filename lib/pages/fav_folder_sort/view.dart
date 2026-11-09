import 'package:pili_aurora/common/widgets/reorder_mixin.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/fav/fav_folder/list.dart';
import 'package:pili_aurora/pages/fav/video/controller.dart';
import 'package:pili_aurora/pages/fav/video/widgets/item.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

class FavFolderSortPage extends StatefulWidget {
  const FavFolderSortPage({super.key, required this.favController});

  final FavController favController;

  @override
  State<FavFolderSortPage> createState() => _FavFolderSortPageState();
}

class _FavFolderSortPageState extends State<FavFolderSortPage>
    with ReorderMixin {
  FavController get _favController => widget.favController;

  late final _source = _favController.loadingState.value.dataOrNull;
  late final _original = List<FavFolderInfo>.of(_source ?? []);
  late final sortList = List<FavFolderInfo>.of(_original);
  bool _saving = false;

  bool get _current =>
      mounted &&
      _favController.isCurrent &&
      identical(_source, _favController.loadingState.value.dataOrNull) &&
      listEquals(_original, _source);

  Future<void> _save() async {
    if (_saving) return;
    if (!_current) {
      SmartDialog.showToast('收藏夹已更新，请重新打开排序');
      return;
    }
    if (listEquals(sortList, _original)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await FavHttp.sortFavFolder(
        account: _favController.account,
        sort: sortList.map((item) => item.id).join(','),
      );
      if (!mounted || !_current) return;
      if (result.isSuccess) {
        _favController.loadingState.value = Success(List.of(sortList));
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
        title: const Text('收藏夹排序'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('完成'),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: _buildBody,
    );
  }

  void onReorderItem(int oldIndex, int newIndex) {
    if (_saving || !_current) return;
    if (oldIndex == 0 || newIndex == 0) {
      SmartDialog.showToast('默认收藏夹不支持排序');
      return;
    }

    sortList.insert(newIndex, sortList.removeAt(oldIndex));

    setState(() {});
  }

  Widget get _buildBody {
    return ReorderableListView.builder(
      onReorderItem: onReorderItem,
      proxyDecorator: proxyDecorator,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: sortList.length,
      padding:
          MediaQuery.viewPaddingOf(context).copyWith(top: 0) +
          const EdgeInsets.only(bottom: 100),
      itemBuilder: (context, index) {
        final item = sortList[index];
        final key = item.id.toString();
        return SizedBox(
          key: Key(key),
          height: 110,
          child: FavVideoItem(
            heroTag: key,
            item: item,
            onLongPress: index == 0
                ? () => SmartDialog.showToast('默认收藏夹不支持排序')
                : null,
          ),
        );
      },
    );
  }
}

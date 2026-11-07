import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/reorder_mixin.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/pages/follow/controller.dart';

class FollowTagSortPage extends ConsumerStatefulWidget {
  const FollowTagSortPage({super.key, required this.initial});
  final FollowTagsState initial;
  @override
  ConsumerState<FollowTagSortPage> createState() => _FollowTagSortPageState();
}

class _FollowTagSortPageState extends ConsumerState<FollowTagSortPage>
    with ReorderMixin {
  late final _defTags = widget.initial.tags
      .where((tag) => !tag.isCustom)
      .toList();
  late final _customTags = widget.initial.tags
      .where((tag) => tag.isCustom)
      .toList();
  @override
  Widget build(BuildContext context) {
    final current = ref.watch(followTagsProvider);
    final valid =
        !current.isLoading &&
        !current.hasError &&
        identical(current.value?.source, widget.initial.source);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('关注分组排序'),
        actions: [
          TextButton(
            onPressed:
                valid &&
                    current.value?.isSaving == false &&
                    _customTags.isNotEmpty
                ? () async {
                    final result = await ref
                        .read(followTagsProvider.notifier)
                        .reorder(
                          _customTags.map((tag) => tag.id).toList(),
                          widget.initial.source,
                        );
                    if (!mounted) return;
                    if (result.isSuccess) {
                      SmartDialog.showToast('排序完成');
                      Get.back();
                    } else {
                      result.toast();
                    }
                  }
                : null,
            child: const Text('完成'),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: valid ? _buildBody : const Center(child: Text('分组或账号已更新，请返回后重试')),
    );
  }

  void onReorderItem(int oldIndex, int newIndex) {
    _customTags.insert(newIndex, _customTags.removeAt(oldIndex));
    setState(() {});
  }

  Widget get _buildBody {
    return ReorderableListView.builder(
      onReorderItem: onReorderItem,
      proxyDecorator: proxyDecorator,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
      ),
      header: Column(
        children: _defTags.map((e) => _buildItem(e, enabled: false)).toList(),
      ),
      itemCount: _customTags.length,
      itemBuilder: (context, index) {
        return _buildItem(_customTags[index]);
      },
    );
  }

  Widget _buildItem(
    FollowTag item, {
    bool enabled = true,
  }) {
    return ListTile(
      textColor: enabled ? null : scheme.outline,
      key: ValueKey(item.id),
      leading: enabled
          ? const Icon(Icons.group_outlined)
          : Icon(
              size: 23,
              Icons.lock_outline,
              color: scheme.outline,
            ),
      minLeadingWidth: 0,
      title: Text('${item.name} (${item.count})'),
      subtitle: item.tip?.isNotEmpty == true ? Text(item.tip!) : null,
    );
  }
}

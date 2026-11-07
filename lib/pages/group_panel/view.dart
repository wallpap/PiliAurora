import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/pages/follow/controller.dart';
import 'package:pili_aurora/pages/follow/widgets/tag_dialog.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

class GroupPanel extends ConsumerStatefulWidget {
  const GroupPanel({
    super.key,
    required this.mid,
    this.tags,
    this.scrollController,
    this.account,
  });
  final int mid;
  final List<int>? tags;
  final ScrollController? scrollController;
  final Account? account;
  @override
  ConsumerState<GroupPanel> createState() => _GroupPanelState();
}

class _GroupPanelState extends ConsumerState<GroupPanel> {
  late final _account = widget.account ?? ref.read(mainAccountProvider);
  late final _initial = Set<int>.from(widget.tags ?? const <int>[])..remove(0);
  late final _selected = Set<int>.of(_initial);
  Object? _source;
  bool get _current => identical(_account, ref.read(mainAccountProvider));
  Future<void> _create() async {
    final before = ref.read(followTagsProvider);
    if (!_current ||
        before.isLoading ||
        before.hasError ||
        before.value == null ||
        before.value!.isSaving ||
        !identical(_source, before.value!.source)) {
      return;
    }
    final name = await showFollowTagNameDialog(context);
    if (!mounted || !_current || name == null) return;
    final result = await ref
        .read(followTagsProvider.notifier)
        .create(name, before.requireValue.source);
    if (!mounted || !_current) return;
    if (result.isSuccess) {
      final created = result.data;
      if (!identical(
        ref.read(followTagsProvider).value?.source,
        created.source,
      )) {
        return;
      }
      setState(() {
        _source = created.source;
        _selected.add(created.id);
      });
      SmartDialog.showToast('创建成功');
    } else {
      result.toast();
    }
  }

  Future<void> _save() async {
    final before = ref.read(followTagsProvider);
    if (!_current ||
        before.isLoading ||
        before.hasError ||
        before.value == null ||
        before.value!.isSaving ||
        !identical(_source, before.value!.source)) {
      return;
    }
    final result = await ref
        .read(followTagsProvider.notifier)
        .assign(widget.mid, _selected, _source!);
    if (!mounted || !_current) return;
    if (result.isSuccess) {
      SmartDialog.showToast('保存成功');
      Get.back(result: Set<int>.of(_selected));
    } else {
      result.toast();
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(mainAccountProvider);
    final snapshot = ref.watch(followTagsProvider);
    final current = identical(account, _account);
    if (current && !snapshot.isLoading && !snapshot.hasError) {
      _source ??= snapshot.value?.source;
    }
    final stale =
        _source != null &&
        !snapshot.isLoading &&
        !snapshot.hasError &&
        !identical(_source, snapshot.value?.source);
    final ready =
        current &&
        !stale &&
        !snapshot.isLoading &&
        !snapshot.hasError &&
        snapshot.value?.isSaving == false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        AppBar(
          backgroundColor: Colors.transparent,
          leading: IconButton(
            tooltip: '关闭',
            onPressed: Get.back,
            icon: const Icon(Icons.close_outlined),
          ),
          title: const Text('设置关注分组'),
          actions: [
            TextButton.icon(
              onPressed: ready ? _create : null,
              icon: const Icon(Icons.add),
              label: const Text('新建分组'),
            ),
            const SizedBox(width: 16),
          ],
        ),
        Expanded(
          child: !current
              ? const Center(child: Text('账号已切换，请重新打开'))
              : stale
              ? const Center(child: Text('分组已更新，请重新打开'))
              : snapshot.when(
                  skipLoadingOnRefresh: false,
                  skipLoadingOnReload: false,
                  loading: () => m3eLoading,
                  error: (_, _) => Center(
                    child: TextButton(
                      onPressed: () => ref.invalidate(followTagsProvider),
                      child: const Text('加载失败，点击重试'),
                    ),
                  ),
                  data: (data) {
                    final tags = data.tags.where((tag) => tag.id != 0).toList();
                    return ListView.builder(
                      controller: widget.scrollController,
                      itemCount: tags.length,
                      itemBuilder: (_, index) {
                        final tag = tags[index];
                        final delta =
                            (_selected.contains(tag.id) ? 1 : 0) -
                            (_initial.contains(tag.id) ? 1 : 0);
                        void toggle() => setState(() {
                          if (!_selected.remove(tag.id)) _selected.add(tag.id);
                        });
                        return ListTile(
                          onTap: ready ? toggle : null,
                          dense: true,
                          leading: const Icon(Icons.group_outlined),
                          minLeadingWidth: 0,
                          title: Text(
                            '${tag.name}${tag.count == null ? '' : ' (${tag.count! + delta})'}',
                          ),
                          subtitle: tag.tip?.isNotEmpty == true
                              ? Text(tag.tip!)
                              : null,
                          trailing: Checkbox(
                            value: _selected.contains(tag.id),
                            onChanged: ready ? (_) => toggle() : null,
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
        Divider(
          height: 1,
          color: Theme.of(context).disabledColor.withValues(alpha: 0.08),
        ),
        Padding(
          padding: EdgeInsets.only(
            right: 20,
            top: 12,
            bottom: MediaQuery.viewPaddingOf(context).bottom + 12,
          ),
          child: FilledButton.tonal(
            onPressed: ready ? _save : null,
            child: Text(_selected.isEmpty ? '保存至默认分组' : '保存'),
          ),
        ),
      ],
    );
  }
}

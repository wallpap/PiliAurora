import 'package:pili_aurora/common/widgets/button/icon_button.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/keep_alive_wrapper.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/dm_block_type.dart';
import 'package:pili_aurora/models/user/danmaku_block.dart';
import 'package:pili_aurora/models/user/danmaku_rule.dart';
import 'package:pili_aurora/pages/danmaku_block/controller.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class DanmakuBlockPage extends ConsumerStatefulWidget {
  const DanmakuBlockPage({super.key});

  @override
  ConsumerState<DanmakuBlockPage> createState() => _DanmakuBlockPageState();
}

class _DanmakuBlockPageState extends ConsumerState<DanmakuBlockPage>
    with SingleTickerProviderStateMixin {
  late final _tabController = TabController(
    length: DmBlockType.values.length,
    vsync: this,
  );
  late PlPlayerController plPlayerController;
  late EdgeInsets padding;

  @override
  void initState() {
    super.initState();
    plPlayerController = Get.arguments as PlPlayerController;
    ref.listenManual(
      danmakuBlockProvider.select((value) => value.rules),
      (_, next) {
        if (next case Success(:final response)) {
          final ruleFilter = RuleFilter.fromRuleTypeEntries(response);
          plPlayerController.filters = ruleFilter;
          GStorage.localCache.put(LocalCacheKey.danmakuFilterRules, ruleFilter);
        }
      },
      fireImmediately: true,
    );
    ref.listenManual(
      danmakuBlockProvider.select((value) => value.notice),
      (_, next) {
        if (next != null) SmartDialog.showToast(next);
      },
      fireImmediately: true,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    padding = MediaQuery.viewPaddingOf(context);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(danmakuBlockProvider);
    final rules = snapshot.rules.dataOrNull;
    final controller = ref.read(danmakuBlockProvider.notifier);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('弹幕屏蔽'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: snapshot.isSaving ? null : controller.reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: rules == null
          ? switch (snapshot.rules) {
              Error(:final errMsg) => scrollErrorWidget(
                errMsg: errMsg,
                onReload: controller.reload,
              ),
              _ => m3eLoading,
            }
          : Column(
              children: [
                if (snapshot.isSaving) const LinearProgressIndicator(),
                TabBar(
                  controller: _tabController,
                  tabs: DmBlockType.values
                      .map(
                        (e) => Tab(
                          text: '${e.label}(${rules[e.index].length})',
                        ),
                      )
                      .toList(),
                ),
                Expanded(
                  child: tabBarView(
                    controller: _tabController,
                    children: DmBlockType.values
                        .map(
                          (e) => KeepAliveWrapper(
                            child: tabViewBuilder(
                              e.index,
                              rules[e.index],
                              snapshot.isSaving,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
      fab: Padding(
        padding: .only(
          right: kFloatingActionButtonMargin + padding.right,
          bottom: kFloatingActionButtonMargin + padding.bottom,
        ),
        child: FloatingActionButton(
          tooltip: '添加',
          onPressed: rules == null || snapshot.isSaving
              ? null
              : () => _showAddDialog(DmBlockType.values[_tabController.index]),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  Widget tabViewBuilder(int tabIndex, List<SimpleRule> list, bool isSaving) {
    if (list.isEmpty) {
      return scrollableError;
    }
    return ListView.builder(
      itemCount: list.length,
      padding: .only(bottom: padding.bottom + 100),
      itemBuilder: (context, itemIndex) {
        final SimpleRule item = list[itemIndex];
        final child = iconButton(
          iconSize: 20,
          tooltip: '删除',
          icon: const Icon(Icons.delete_outlined),
          onPressed: isSaving
              ? null
              : () {
                  final rules = ref.read(danmakuBlockProvider).rules.dataOrNull;
                  showConfirmDialog(
                    context: context,
                    title: const Text('确定删除该规则？'),
                    onConfirm: () async {
                      if (!_hasCurrentRules(rules)) return;
                      final result = await ref
                          .read(danmakuBlockProvider.notifier)
                          .remove(
                            DmBlockType.values[tabIndex],
                            item.id,
                          );
                      if (!mounted) return;
                      if (result.isSuccess) {
                        SmartDialog.showToast('删除成功');
                      } else {
                        result.toast();
                      }
                    },
                  );
                },
        );
        return ListTile(
          title: Text(
            item.filter,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          trailing: tabIndex == 2
              ? child
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    iconButton(
                      iconSize: 20,
                      tooltip: '编辑',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: isSaving
                          ? null
                          : () => _showAddDialog(
                              DmBlockType.values[tabIndex],
                              initFilter: item.filter,
                              itemId: item.id,
                            ),
                    ),
                    child,
                  ],
                ),
        );
      },
    );
  }

  void _showAddDialog(
    DmBlockType type, {
    String initFilter = '',
    int? itemId,
  }) {
    final rules = ref.read(danmakuBlockProvider).rules.dataOrNull;
    String filter = initFilter;
    final hintText = switch (type) {
      DmBlockType.keyword => '输入过滤的关键词，其它类别请切换标签页后添加',
      DmBlockType.regex => '输入//之间的正则表达式，无需包含头尾的"/"',
      DmBlockType.uid => '输入用户UID',
    };
    final isUid = type == DmBlockType.uid;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${itemId != null ? "编辑" : "添加新的"}${type.label}规则'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hintText),
            TextFormField(
              autofocus: true,
              initialValue: filter,
              onChanged: (value) => filter = value,
              keyboardType: isUid ? TextInputType.number : null,
              inputFormatters: isUid
                  ? [FilteringTextInputFormatter.digitsOnly]
                  : null,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            child: const Text('确定'),
            onPressed: () async {
              if (filter.isNotEmpty && filter != initFilter) {
                Get.back();
                if (!_hasCurrentRules(rules)) return;
                final result = await ref
                    .read(danmakuBlockProvider.notifier)
                    .save(
                      type,
                      filter,
                      replaceId: itemId,
                    );
                if (!mounted) return;
                if (result.isSuccess) {
                  SmartDialog.showToast(itemId == null ? '添加成功' : '编辑成功');
                } else {
                  result.toast();
                }
              } else {
                SmartDialog.showToast(
                  '输入内容${filter.isEmpty ? "不能为空" : "与上次相同"}',
                );
              }
            },
          ),
        ],
      ),
    );
  }

  bool _hasCurrentRules(List<List<SimpleRule>>? rules) =>
      mounted &&
      rules != null &&
      identical(rules, ref.read(danmakuBlockProvider).rules.dataOrNull);
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/live/live_dm_block/shield_user_list.dart';
import 'package:pili_aurora/pages/live_dm_block/controller.dart';
import 'package:pili_aurora/pages/search/widgets/search_text.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class LiveDmBlockPage extends ConsumerStatefulWidget {
  const LiveDmBlockPage({super.key});
  @override
  ConsumerState<LiveDmBlockPage> createState() => _LiveDmBlockPageState();
}

class _LiveDmBlockPageState extends ConsumerState<LiveDmBlockPage>
    with SingleTickerProviderStateMixin {
  late final String _roomId = Get.parameters['roomId']!;
  late final TabController _tabs = TabController(length: 2, vsync: this);
  late final Account _initialAccount;
  LiveBlockRulesChanged? _onChanged;
  @override
  void initState() {
    super.initState();
    _initialAccount = ref.read(mainAccountProvider);
    if (Get.arguments case final LiveBlockRulesChanged callback) {
      _onChanged = callback;
    }
    ref.listenManual(liveBlockProvider(_roomId), (_, next) {
      final data = next.value;
      if (!next.isLoading && !next.hasError && data != null && !data.saving) {
        if (identical(ref.read(mainAccountProvider), _initialAccount)) {
          _onChanged?.call(data.keywords, data.users.map((e) => e.uid).toSet());
        }
      }
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _report(Future<LoadingState<void>> operation) async {
    final result = await operation;
    if (mounted && !result.isSuccess) result.toast();
  }

  void _change(
    LiveBlockState data,
    bool keyword,
    String value, {
    bool remove = false,
  }) {
    if (!mounted) return;
    _report(
      ref
          .read(liveBlockProvider(_roomId).notifier)
          .change(
            source: data.source,
            keyword: keyword,
            value: value,
            remove: remove,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = liveBlockProvider(_roomId);
    final snapshot = ref.watch(provider);
    final data = !snapshot.isLoading && !snapshot.hasError
        ? snapshot.value
        : null;
    final padding = MediaQuery.viewPaddingOf(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('弹幕屏蔽'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: data?.saving == true
                ? null
                : () => ref.invalidate(provider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.only(left: padding.left, right: padding.right),
        child: Column(
          children: [
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: '关键词'),
                Tab(text: '用户'),
              ],
            ),
            if (data?.saving == true) const LinearProgressIndicator(),
            Expanded(
              child: snapshot.when(
                skipLoadingOnRefresh: false,
                skipLoadingOnReload: false,
                loading: () => const SizedBox.shrink(),
                error: (error, _) => scrollErrorWidget(
                  errMsg: error.toString(),
                  onReload: () => ref.invalidate(provider),
                ),
                data: (data) => tabBarView(
                  controller: _tabs,
                  hitTestBehavior: .translucent,
                  children: [
                    _rules(data, data.keywords, padding.bottom),
                    _rules(data, data.users, padding.bottom),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      fab: Padding(
        padding: EdgeInsets.only(
          right: kFloatingActionButtonMargin + padding.right,
          bottom: kFloatingActionButtonMargin + padding.bottom,
        ),
        child: FloatingActionButton(
          tooltip: '添加',
          onPressed: data == null || data.saving ? null : () => _add(data),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  Widget _rules(LiveBlockState data, List<Object> rules, double bottom) {
    if (rules.isEmpty) return scrollableError;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(12, 12, 12, bottom + 100),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final item in rules)
            SearchText(
              text: item is ShieldUserList ? item.uname : item as String,
              onTap: (_) {
                if (data.saving) return;
                showConfirmDialog(
                  context: context,
                  title: const Text('确定删除该规则？'),
                  onConfirm: () => _change(
                    data,
                    item is String,
                    item is ShieldUserList
                        ? item.uid.toString()
                        : item as String,
                    remove: true,
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  void _add(LiveBlockState data) {
    final keyword = _tabs.index == 0;
    var value = '';
    showConfirmDialog(
      context: context,
      title: Text('${keyword ? '关键词' : '用户'}屏蔽'),
      content: TextFormField(
        autofocus: true,
        onChanged: (text) => value = text,
        decoration: keyword ? null : const InputDecoration(hintText: 'UID'),
        keyboardType: keyword ? null : TextInputType.number,
        inputFormatters: keyword
            ? null
            : [FilteringTextInputFormatter.digitsOnly],
      ),
      onConfirm: () => _change(data, keyword, value),
    );
  }
}

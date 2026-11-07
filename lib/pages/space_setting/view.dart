import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/models/remote/space_setting/privacy.dart';
import 'package:pili_aurora/pages/space_setting/controller.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

class SpaceSettingPage extends ConsumerStatefulWidget {
  const SpaceSettingPage({super.key});
  @override
  ConsumerState<SpaceSettingPage> createState() => _SpaceSettingPageState();
}

class _SpaceSettingPageState extends ConsumerState<SpaceSettingPage> {
  String? _error;
  Account? _errorAccount;
  Account? _savingAccount;
  Future<void> _save({bool leave = false}) async {
    final account = ref.read(mainAccountProvider);
    if (identical(_savingAccount, account)) return;
    _savingAccount = account;
    final route = ModalRoute.of(context);
    final result = await ref.read(spacePrivacyProvider.notifier).save();
    if (!mounted) return;
    if (!identical(_savingAccount, account)) return;
    _savingAccount = null;
    if (!identical(ref.read(mainAccountProvider), account)) return;
    setState(() {
      _errorAccount = account;
      _error = result.isSuccess ? null : result.toString();
    });
    if (leave && result.isSuccess && route?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(spacePrivacyProvider);
    final account = ref.watch(mainAccountProvider);
    final data = !snapshot.isLoading && !snapshot.hasError
        ? snapshot.value
        : null;
    return PopScope(
      canPop: data == null || (!data.dirty && !data.saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _save(leave: true);
      },
      child: SimpleScaffold(
        appBar: AppBar(
          title: const Text('空间设置'),
          actions: [
            TextButton(
              onPressed: data?.dirty == true && data?.saving == false
                  ? _save
                  : null,
              child: Text(data?.saving == true ? '保存中' : '保存'),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_error != null && identical(_errorAccount, account))
              Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
            Expanded(
              child: snapshot.when(
                skipLoadingOnRefresh: false,
                skipLoadingOnReload: false,
                loading: () => const SizedBox.shrink(),
                error: (_, _) => scrollErrorWidget(
                  onReload: () => ref.invalidate(spacePrivacyProvider),
                ),
                data: (data) => _buildBody(Theme.of(context), data),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, SpacePrivacyState data) => Builder(
    builder: (context) {
      final padding = MediaQuery.viewPaddingOf(context);
      final divider = Divider(
        height: 1,
        indent: max(16, padding.left),
        color: theme.colorScheme.outline.withValues(alpha: 0.1),
      );
      final dividerL = SliverToBoxAdapter(
        child: Divider(
          height: 12,
          thickness: 12,
          color: theme.colorScheme.outline.withValues(alpha: 0.1),
        ),
      );
      return CustomScrollView(
        slivers: [
          dividerL,
          SliverList.separated(
            itemCount: data.privacy.list1.length,
            itemBuilder: (context, index) {
              return _item(data, data.privacy.list1[index]);
            },
            separatorBuilder: (context, index) => divider,
          ),
          dividerL,
          SliverList.separated(
            itemCount: data.privacy.list2.length,
            itemBuilder: (context, index) {
              return _item(data, data.privacy.list2[index]);
            },
            separatorBuilder: (context, index) => divider,
          ),
          dividerL,
          SliverList.separated(
            itemCount: data.privacy.list3.length,
            itemBuilder: (context, index) {
              return _item(data, data.privacy.list3[index]);
            },
            separatorBuilder: (context, index) => divider,
          ),
          dividerL,
          SliverToBoxAdapter(
            child: SizedBox(height: padding.bottom + 100),
          ),
        ],
      );
    },
  );
  Widget _item(SpacePrivacyState data, SpaceSettingModel item) {
    final value = data.values[item.key];
    final checked = item.isReverse ? value == 0 : value == 1;
    void changed(bool value) =>
        ref.read(spacePrivacyProvider.notifier).setValue(item.key, value);
    return ListTile(
      dense: true,
      onTap: data.saving ? null : () => changed(!checked),
      title: Text(item.name, style: const TextStyle(fontSize: 14)),
      trailing: Transform.scale(
        alignment: Alignment.centerRight,
        scale: 0.8,
        child: Switch(value: checked, onChanged: data.saving ? null : changed),
      ),
    );
  }
}

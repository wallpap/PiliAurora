import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/reply.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/models/remote/emote/package.dart';
import 'package:pili_aurora/models/remote/emote/setting_panel.dart';
import 'package:pili_aurora/pages/emote/preview.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/utils/page_utils.dart';

/// 原生管理评论区表情包。
class EmoteManagePage extends StatefulWidget {
  const EmoteManagePage({super.key});

  @override
  State<EmoteManagePage> createState() => _EmoteManagePageState();
}

class _EmoteManagePageState extends State<EmoteManagePage> {
  final _searchController = TextEditingController();
  final _busyPackageIds = <int>{};
  EmoteSettingPanel? _panel;
  String? _error;
  bool _loading = true;
  String _keyword = '';
  int _category = 0;
  int _generation = 0;
  late Account _account;
  final _categoryPackages = <int, List<Package>>{};
  final _categoryErrors = <int, String>{};
  final _loadingCategories = <int>{};
  static const _categories = ['全部表情', '装扮商城', '会员专属', '包月充电'];
  static const _webUrl =
      'https://www.bilibili.com/h5/mall/emoji-package/home?navhide=1';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final account = _account = Accounts.main;
    _categoryPackages.clear();
    _categoryErrors.clear();
    _loadingCategories.clear();
    _busyPackageIds.clear();
    setState(() {
      _loading = true;
      _error = null;
      _panel = null;
    });
    final result = await ReplyHttp.getEmoteSettingPanel(account: account);
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      if (!identical(account, Accounts.main)) {
        _error = '账号已切换，请刷新重试';
      } else if (result case Success(:final response)) {
        _panel = response;
      } else {
        _error = result.toString();
      }
    });
    if (_panel != null && _error == null) await _loadCategory(_category);
  }

  Future<void> _loadCategory(int category) async {
    if (!identical(_account, Accounts.main)) return _load();
    setState(() => _category = category);
    if (_categoryPackages.containsKey(category) ||
        !_loadingCategories.add(category)) {
      return;
    }
    final generation = _generation;
    final account = _account;
    setState(() => _categoryErrors.remove(category));
    final result = await ReplyHttp.getMyEmotePackages(
      type: category,
      account: account,
    );
    if (!mounted || generation != _generation) return;
    if (!identical(account, Accounts.main)) return _load();
    setState(() {
      _loadingCategories.remove(category);
      if (result case Success(:final response)) {
        _categoryPackages[category] = response;
      } else {
        _categoryErrors[category] = result.toString();
      }
    });
  }

  Future<void> _changePackage(Package package, {required bool add}) async {
    if (!identical(_account, Accounts.main)) return _load();
    final panel = _panel;
    final id = package.id;
    if (panel == null || id == null || _busyPackageIds.contains(id)) return;
    final account = _account;
    final generation = _generation;
    setState(() => _busyPackageIds.add(id));
    try {
      final result = add
          ? await ReplyHttp.addEmotePackage(packageId: id, account: account)
          : await ReplyHttp.removeEmotePackage(packageId: id, account: account);
      if (!mounted || generation != _generation || !identical(panel, _panel)) {
        return;
      }
      if (!identical(account, Accounts.main)) {
        await _load();
        return;
      }
      if (result is Success<void>) {
        SmartDialog.showToast(add ? '添加成功' : '移除成功');
        setState(() {
          if (add) {
            if (!panel.userPanelPackages.any((item) => item.id == id)) {
              panel.userPanelPackages.add(package);
            }
          } else {
            panel.userPanelPackages.removeWhere((item) => item.id == id);
            if (!panel.allPackages.any((item) => item.id == id)) {
              panel.allPackages.add(package);
            }
            final all = _categoryPackages[0];
            if (all != null && !all.any((item) => item.id == id)) {
              all.add(package);
            }
          }
          for (final item in [
            ...panel.userPanelPackages,
            ...panel.allPackages,
            ..._categoryPackages.values.expand((items) => items),
          ]) {
            if (item.id == id) item.flags = EmotePackageFlags(added: add);
          }
        });
      } else {
        result.toast();
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busyPackageIds.remove(id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final panel = _panel;
    final addedIds = panel?.userPanelPackages.map((e) => e.id).toSet() ?? {};
    final added =
        panel?.userPanelPackages
            .where((package) => (package.id ?? 0) > 0 && package.text != '收藏')
            .toList() ??
        const <Package>[];
    final available =
        _categoryPackages[_category]
            ?.where(
              (package) =>
                  (package.id ?? 0) > 0 &&
                  package.text != '收藏' &&
                  !addedIds.contains(package.id),
            )
            .toList() ??
        const <Package>[];

    return DefaultTabController(
      length: 2,
      child: SimpleScaffold(
        appBar: AppBar(
          title: const Text('表情包管理'),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: _loading || _busyPackageIds.isNotEmpty ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: '在浏览器中打开',
              onPressed: () => PageUtils.launchURL(_webUrl),
              icon: const Icon(Icons.open_in_browser),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          bottom: true,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _keyword = value.trim()),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: '搜索表情包',
                    suffixIcon: _keyword.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _keyword = '');
                            },
                            icon: const Icon(Icons.clear),
                          ),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              TabBar(
                tabs: [
                  Tab(text: '已添加 (${added.length})'),
                  Tab(text: '未添加 (${available.length})'),
                ],
              ),
              Expanded(
                child: _loading
                    ? m3eLoading
                    : _error != null
                    ? Center(
                        child: TextButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: Text(_error!),
                        ),
                      )
                    : TabBarView(
                        children: [
                          _buildPackageList(added, add: false),
                          _buildAvailablePackages(available),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvailablePackages(List<Package> packages) => Column(
    children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var category = 0; category < _categories.length; category++)
              Padding(
                padding: const EdgeInsets.all(4),
                child: ChoiceChip(
                  label: Text(_categories[category]),
                  selected: _category == category,
                  onSelected: (_) => _loadCategory(category),
                ),
              ),
          ],
        ),
      ),
      Expanded(
        child: _loadingCategories.contains(_category)
            ? m3eLoading
            : _categoryErrors.containsKey(_category)
            ? Center(
                child: TextButton(
                  onPressed: () => _loadCategory(_category),
                  child: Text('${_categoryErrors[_category]}，点击重试'),
                ),
              )
            : _buildPackageList(packages, add: true),
      ),
    ],
  );

  Widget _buildPackageList(List<Package> packages, {required bool add}) {
    final filtered = packages
        .where(
          (package) =>
              (_keyword.isEmpty ||
              (package.text?.toLowerCase().contains(
                    _keyword.toLowerCase(),
                  ) ??
                  false)),
        )
        .toList();
    if (filtered.isEmpty) {
      return Center(
        child: Text(_keyword.isEmpty ? '暂无表情包' : '没有匹配的表情包'),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: filtered.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final package = filtered[index];
        final id = package.id;
        final busy = id != null && _busyPackageIds.contains(id);
        return ListTile(
          onTap: id == null
              ? null
              : () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => EmotePackagePreviewPage(package: package),
                  ),
                ),
          leading: NetworkImgLayer(
            src: package.url,
            width: 44,
            height: 44,
            type: ImageType.emote,
            fit: BoxFit.contain,
          ),
          title: Text(package.text ?? '未命名表情包'),
          subtitle: Text(
            [
              if (package.emote != null) '${package.emote!.length} 个表情',
            ].join(' · '),
          ),
          trailing: busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  tooltip: add ? '添加' : '移除',
                  onPressed: id == null
                      ? null
                      : () => _changePackage(package, add: add),
                  icon: Icon(add ? Icons.add_circle_outline : Icons.remove),
                ),
        );
      },
    );
  }
}

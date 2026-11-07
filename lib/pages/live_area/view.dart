import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/common/widgets/button/icon_button.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/models/remote/live/live_area_list/area_item.dart';
import 'package:pili_aurora/models/remote/live/live_area_list/area_list.dart';
import 'package:pili_aurora/pages/live_area/controller.dart';
import 'package:pili_aurora/pages/live_area_detail/view.dart';
import 'package:pili_aurora/pages/search/widgets/search_text.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:flutter_sortable_wrap/sortable_wrap.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

class LiveAreaPage extends ConsumerStatefulWidget {
  const LiveAreaPage({super.key});
  @override
  ConsumerState<LiveAreaPage> createState() => _LiveAreaPageState();
}

class _LiveAreaPageState extends ConsumerState<LiveAreaPage> {
  Object? _source;
  List<AreaItem>? _draft;
  Object? _savingSource;
  bool _saving(LiveAreaPreferences? data) =>
      data != null && identical(_savingSource, data.source);
  bool _editing(LiveAreaPreferences? data) =>
      data != null && identical(_source, data.source) && _draft != null;
  Future<void> _edit(LiveAreaPreferences data) async {
    if (_saving(data)) return;
    if (!_editing(data)) {
      setState(() {
        _source = data.source;
        _draft = [...data.items];
      });
      return;
    }
    final account = ref.read(mainAccountProvider);
    setState(() => _savingSource = data.source);
    final result = await ref
        .read(liveAreaPreferencesProvider.notifier)
        .save(data.source, _draft!);
    if (!mounted || !identical(_savingSource, data.source)) return;
    if (!identical(ref.read(mainAccountProvider), account) ||
        !identical(_source, data.source)) {
      return;
    }
    setState(() {
      _savingSource = null;
      if (result.isSuccess) {
        _source = null;
        _draft = null;
      }
    });
    if (!result.isSuccess) result.toast();
  }

  void _toggle(AreaItem item) {
    if ((_savingSource != null && identical(_savingSource, _source)) ||
        item.id == 0) {
      return;
    }
    setState(() {
      if (!_draft!.remove(item)) _draft!.add(item);
    });
  }

  void _open(AreaItem item) => Get.to(
    LiveAreaDetailPage(
      areaId: item.id,
      parentAreaId: item.parentId,
      parentName: item.parentName ?? '',
    ),
  );
  @override
  Widget build(BuildContext context) {
    final account = ref.watch(mainAccountProvider);
    final areas = ref.watch(liveAreasProvider);
    final prefs = account.isLogin
        ? ref.watch(liveAreaPreferencesProvider)
        : null;
    final data = prefs != null && !prefs.isLoading && !prefs.hasError
        ? prefs.value
        : null;
    final editing = _editing(data);
    final items = editing ? _draft! : data?.items ?? <AreaItem>[];
    final padding = MediaQuery.viewPaddingOf(context);
    final theme = Theme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('全部标签'),
        actions: [
          if (data != null)
            TextButton(
              onPressed: _saving(data) || data.saving
                  ? null
                  : () => _edit(data),
              child: Text(
                _saving(data)
                    ? '保存中'
                    : editing
                    ? '完成'
                    : '编辑',
              ),
            ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.only(left: padding.left, right: padding.right),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (prefs?.hasError == true)
              TextButton(
                onPressed: () => ref.invalidate(liveAreaPreferencesProvider),
                child: const Text('常用标签加载失败，重试'),
              ),
            if (data != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('我的常用标签  点击进入标签'),
                    const SizedBox(height: 8),
                    if (items.isNotEmpty)
                      SortableWrap(
                        spacing: 12,
                        runSpacing: 8,
                        onSortStart: (_) {
                          if (_saving(data) || data.saving) return;
                          if (!editing) {
                            setState(() {
                              _source = data.source;
                              _draft = [...data.items];
                            });
                          }
                        },
                        onSorted: (oldIndex, newIndex) {
                          if (_saving(data) || data.saving || !_editing(data)) {
                            return;
                          }
                          setState(
                            () => _draft!.insert(
                              newIndex,
                              _draft!.removeAt(oldIndex),
                            ),
                          );
                        },
                        children: [
                          for (final item in items)
                            Stack(
                              clipBehavior: Clip.none,
                              children: [
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: theme.colorScheme.outline,
                                    ),
                                    color: theme.colorScheme.surface,
                                    borderRadius: const BorderRadius.all(
                                      Radius.circular(4),
                                    ),
                                  ),
                                  child: SearchText(
                                    text: item.name ?? '',
                                    fontSize: 14,
                                    bgColor: Colors.transparent,
                                    padding: const .symmetric(
                                      horizontal: 12,
                                      vertical: 4,
                                    ),
                                    onTap: (_) =>
                                        editing ? _toggle(item) : _open(item),
                                  ),
                                ),
                                if (editing)
                                  Positioned(
                                    right: -4,
                                    top: -4,
                                    child: iconButton(
                                      size: 16,
                                      iconSize: 12,
                                      icon: const Icon(Icons.horizontal_rule),
                                      bgColor: theme.colorScheme.errorContainer,
                                      iconColor:
                                          theme.colorScheme.onErrorContainer,
                                      onPressed: () => _toggle(item),
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            Expanded(
              child: areas.when(
                skipLoadingOnRefresh: false,
                skipLoadingOnReload: false,
                loading: () => const SizedBox.shrink(),
                error: (error, _) => scrollErrorWidget(
                  errMsg: error.toString(),
                  onReload: () => ref.invalidate(liveAreasProvider),
                ),
                data: (list) => list.isEmpty
                    ? scrollErrorWidget(
                        onReload: () => ref.invalidate(liveAreasProvider),
                      )
                    : _AreaTabs(
                        areas: list,
                        bottom: padding.bottom,
                        itemBuilder: (item) => GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => editing ? _toggle(item) : _open(item),
                          child: Stack(
                            alignment: Alignment.center,
                            clipBehavior: Clip.none,
                            children: [
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  NetworkImgLayer(
                                    width: 45,
                                    height: 45,
                                    src: item.pic,
                                    type: ImageType.emote,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    item.name ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                              if (editing && item.id != 0)
                                Positioned(
                                  top: 0,
                                  right: 16,
                                  child: iconButton(
                                    size: 17,
                                    iconSize: 13,
                                    icon: Icon(
                                      items.contains(item)
                                          ? MdiIcons.check
                                          : MdiIcons.plus,
                                    ),
                                    bgColor:
                                        theme.colorScheme.secondaryContainer,
                                    iconColor:
                                        theme.colorScheme.onSecondaryContainer,
                                    onPressed: () => _toggle(item),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AreaTabs extends StatefulWidget {
  const _AreaTabs({
    required this.areas,
    required this.bottom,
    required this.itemBuilder,
  });
  final List<AreaList> areas;
  final double bottom;
  final Widget Function(AreaItem) itemBuilder;
  @override
  State<_AreaTabs> createState() => _AreaTabsState();
}

class _AreaTabsState extends State<_AreaTabs>
    with SingleTickerProviderStateMixin {
  late TabController _tabs = TabController(
    length: widget.areas.length,
    vsync: this,
  );
  @override
  void didUpdateWidget(_AreaTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.areas.length != oldWidget.areas.length) {
      final index = _tabs.index.clamp(0, widget.areas.length - 1);
      _tabs.dispose();
      _tabs = TabController(
        length: widget.areas.length,
        initialIndex: index,
        vsync: this,
      );
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TabBar(
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        controller: _tabs,
        tabs: [for (final area in widget.areas) Tab(text: area.name)],
      ),
      Expanded(
        child: tabBarView(
          controller: _tabs,
          children: [
            for (final area in widget.areas)
              GridView.builder(
                padding: EdgeInsets.only(top: 12, bottom: widget.bottom + 100),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 100,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  mainAxisExtent: 80,
                ),
                itemCount: area.areaList?.length ?? 0,
                itemBuilder: (_, index) =>
                    widget.itemBuilder(area.areaList![index]),
              ),
          ],
        ),
      ),
    ],
  );
}

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:pili_aurora/common/widgets/view_safe_area.dart';
import 'package:pili_aurora/pages/common/search/scoped_search.dart';
import 'package:pili_aurora/pages/live_search/child/view.dart';
import 'package:pili_aurora/models/common/live/live_search_type.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';

class LiveSearchPage extends ConsumerStatefulWidget {
  const LiveSearchPage({super.key});
  @override
  ConsumerState<LiveSearchPage> createState() => _LiveSearchPageState();
}

class _LiveSearchPageState extends ConsumerState<LiveSearchPage>
    with SingleTickerProviderStateMixin {
  final _input = TextEditingController();
  final _focus = FocusNode();
  late final _tabs = TabController(length: 2, vsync: this);
  final _keys = [
    GlobalKey<LiveSearchChildPageState>(),
    GlobalKey<LiveSearchChildPageState>(),
  ];
  String? _keyword;
  Object _owner = Object();
  final int? _mid = null;
  void _submit() {
    final value = _input.text.trim();
    if (value.isEmpty) return;
    if (IdUtils.digitOnlyRegExp.hasMatch(value)) {
      final roomId = int.tryParse(value);
      if (roomId == null || roomId <= 0) {
        SmartDialog.showToast('请输入有效的直播间号');
        return;
      }
      PageUtils.toLiveRoom(roomId);
      return;
    }
    setState(() {
      _keyword = value;
      _owner = Object();
    });
    _focus.unfocus();
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyword = _keyword;
    final kinds = [ScopedSearchKind.room, ScopedSearchKind.user];
    final counts = [
      for (final kind in kinds)
        if (keyword != null)
          ref.watch(
            scopedSearchProvider((
              kind: kind,
              keyword: keyword,
              mid: _mid,
              owner: _owner,
            )),
          ),
    ];
    String count(int index) {
      if (counts.isEmpty || counts[index].isLoading || counts[index].hasError) {
        return '';
      }
      return counts[index].value?.total?.toString() ?? '';
    }

    return SimpleScaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: '搜索',
            onPressed: _submit,
            icon: const Icon(Icons.search, size: 22),
          ),
          const SizedBox(width: 10),
        ],
        title: TextField(
          autofocus: true,
          focusNode: _focus,
          controller: _input,
          textInputAction: TextInputAction.search,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            hintText: '搜索房间或主播',
            border: InputBorder.none,
            suffixIcon: IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.clear, size: 22),
              onPressed: () {
                if (_input.text.isEmpty) {
                  Get.back();
                  return;
                }
                _input.clear();
                setState(() => _keyword = null);
                _focus.requestFocus();
              },
            ),
          ),
          onSubmitted: (_) => _submit(),
          onChanged: (_) {
            if (_keyword != null) setState(() => _keyword = null);
          },
        ),
      ),
      body: ViewSafeArea(
        child: keyword == null
            ? const SizedBox.shrink()
            : Column(
                children: [
                  TabBar(
                    controller: _tabs,
                    tabs: [
                      Tab(text: '正在直播 ${count(0)}'),
                      Tab(text: '主播 ${count(1)}'),
                    ],
                    onTap: (index) {
                      if (!_tabs.indexIsChanging) {
                        _keys[index].currentState?.scrollToTop();
                      }
                    },
                  ),
                  Expanded(
                    child: tabBarView(
                      controller: _tabs,
                      children: [
                        for (var i = 0; i < 2; i++)
                          LiveSearchChildPage(
                            key: _keys[i],
                            keyword: keyword,
                            owner: _owner,
                            mid: _mid,
                            searchType: LiveSearchType.values[i],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/pages/follow/child/child_view.dart';
import 'package:pili_aurora/pages/follow/controller.dart';
import 'package:pili_aurora/pages/share/view.dart' show UserModel;
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/parse_int.dart';

class FollowSearchPage extends ConsumerStatefulWidget {
  const FollowSearchPage({super.key, this.mid, this.isFromSelect = false});
  final int? mid;
  final bool isFromSelect;
  factory FollowSearchPage.fromArguments(Object? arguments) =>
      FollowSearchPage(mid: safeToInt((arguments as Map?)?['mid']));
  @override
  ConsumerState<FollowSearchPage> createState() => _FollowSearchPageState();
}

class _FollowSearchPageState extends ConsumerState<FollowSearchPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  String? _submitted;
  void _search() {
    final value = _input.text.trim();
    if (value.isEmpty) return;
    if (_submitted == value) {
      ref.invalidate(
        followingProvider((mid: widget.mid, tagid: null, keyword: value)),
      );
    }
    setState(() => _submitted = value);
    _focus.unfocus();
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(mainAccountProvider);
    return SimpleScaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          controller: _input,
          focusNode: _focus,
          textInputAction: TextInputAction.search,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            hintText: '搜索',
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
                setState(() => _submitted = null);
                _focus.requestFocus();
              },
            ),
          ),
          onChanged: (_) {
            if (_submitted != null) setState(() => _submitted = null);
          },
          onSubmitted: (_) => _search(),
        ),
        actions: [
          IconButton(
            tooltip: '搜索',
            onPressed: _search,
            icon: const Icon(Icons.search_outlined, size: 22),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: _submitted == null
          ? const SizedBox.shrink()
          : FollowChildPage(
              key: ValueKey((account, _submitted)),
              mid: widget.mid,
              keyword: _submitted,
              onSelect: widget.isFromSelect
                  ? (UserModel user) => Get.back(result: user)
                  : null,
            ),
    );
  }
}

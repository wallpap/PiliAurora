import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:pili_aurora/pages/follow_type/controller.dart';
import 'package:pili_aurora/pages/follow_type/view.dart';
import 'package:pili_aurora/pages/follow/child/child_view.dart';
import 'package:pili_aurora/pages/follow_search/view.dart';
import 'package:pili_aurora/pages/share/view.dart' show UserModel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class ContactPage extends ConsumerStatefulWidget {
  const ContactPage({super.key, this.isFromSelect = true});

  final bool isFromSelect;

  @override
  ConsumerState<ContactPage> createState() => _ContactPageState();
}

class _ContactPageState extends ConsumerState<ContactPage>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void onSelect(UserModel userModel) {
    Get.back(result: userModel);
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(mainAccountProvider);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('通讯录'),
        actions: [
          IconButton(
            onPressed: () async {
              final UserModel? userModel = await Navigator.of(context).push(
                GetPageRoute(
                  page: () => FollowSearchPage(
                    isFromSelect: widget.isFromSelect,
                  ),
                ),
              );
              if (mounted &&
                  identical(account, ref.read(mainAccountProvider)) &&
                  userModel != null) {
                Get.back(result: userModel);
              }
            },
            icon: const Icon(Icons.search),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          TabBar(
            controller: _controller,
            tabs: const [
              Tab(text: '我的关注'),
              Tab(text: '我的粉丝'),
            ],
          ),
          Expanded(
            child: tabBarView(
              controller: _controller,
              children: [
                FollowChildPage(
                  key: ObjectKey(account),
                  onSelect: widget.isFromSelect ? onSelect : null,
                ),
                FollowTypePage(
                  query: (kind: FollowKind.fans, mid: null, newFans: false),
                  showName: false,
                  onSelect: widget.isFromSelect ? onSelect : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

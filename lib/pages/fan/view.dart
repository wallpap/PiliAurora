import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/follow_type/controller.dart';
import 'package:pili_aurora/pages/follow_type/view.dart';
import 'package:pili_aurora/pages/share/view.dart' show UserModel;
import 'package:pili_aurora/utils/parse_int.dart';

class FansPage extends StatefulWidget {
  const FansPage({super.key, this.showName = true, this.onSelect});
  final bool showName;
  final ValueChanged<UserModel>? onSelect;
  @override
  State<FansPage> createState() => _FansPageState();
  static void toFansPage({dynamic mid, String? name}) {
    if (mid == null) return;
    Get.toNamed('/fan', arguments: {'mid': safeToInt(mid), 'name': name});
  }
}

class _FansPageState extends State<FansPage> {
  late final Map? args = widget.showName ? Get.arguments as Map? : null;
  @override
  Widget build(BuildContext context) => FollowTypePage(
    query: (
      kind: FollowKind.fans,
      mid: args?['mid'] as int?,
      newFans: args?['newFans'] == true,
    ),
    name: args?['name'] as String?,
    showName: widget.showName,
    onSelect: widget.onSelect,
  );
}

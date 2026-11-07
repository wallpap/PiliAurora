import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/follow_type/controller.dart';
import 'package:pili_aurora/pages/follow_type/view.dart';
import 'package:pili_aurora/utils/parse_int.dart';

class FollowedPage extends StatefulWidget {
  const FollowedPage({super.key});
  @override
  State<FollowedPage> createState() => _FollowedPageState();
  static void toFollowedPage({dynamic mid, String? name}) {
    if (mid == null) return;
    Get.toNamed('/followed', arguments: {'mid': safeToInt(mid), 'name': name});
  }
}

class _FollowedPageState extends State<FollowedPage> {
  late final Map? args = Get.arguments as Map?;
  @override
  Widget build(BuildContext context) => FollowTypePage(
    query: (
      kind: FollowKind.followed,
      mid: args?['mid'] as int?,
      newFans: false,
    ),
    name: args?['name'] as String?,
  );
}

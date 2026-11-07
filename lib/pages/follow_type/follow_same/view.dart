import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/follow_type/controller.dart';
import 'package:pili_aurora/pages/follow_type/view.dart';
import 'package:pili_aurora/utils/parse_int.dart';

class FollowSamePage extends StatefulWidget {
  const FollowSamePage({super.key});
  @override
  State<FollowSamePage> createState() => _FollowSamePageState();
  static void toFollowSamePage({dynamic mid, String? name}) {
    if (mid == null) return;
    Get.toNamed(
      '/sameFollowing',
      arguments: {'mid': safeToInt(mid), 'name': name},
    );
  }
}

class _FollowSamePageState extends State<FollowSamePage> {
  late final Map? args = Get.arguments as Map?;
  @override
  Widget build(BuildContext context) => FollowTypePage(
    query: (kind: FollowKind.same, mid: args?['mid'] as int?, newFans: false),
    name: args?['name'] as String?,
  );
}

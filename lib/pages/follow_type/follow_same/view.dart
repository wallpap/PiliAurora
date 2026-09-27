import 'package:pili_aurora/pages/follow_type/follow_same/controller.dart';
import 'package:pili_aurora/pages/follow_type/view.dart';
import 'package:pili_aurora/utils/extension/get_ext.dart';
import 'package:pili_aurora/utils/parse_int.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class FollowSamePage extends StatefulWidget {
  const FollowSamePage({super.key});

  @override
  State<FollowSamePage> createState() => _FollowSamePageState();

  static void toFollowSamePage({dynamic mid, String? name}) {
    if (mid == null) return;
    Get.toNamed(
      '/sameFollowing',
      arguments: {
        'mid': safeToInt(mid),
        'name': name,
      },
    );
  }
}

class _FollowSamePageState extends FollowTypePageState<FollowSamePage> {
  @override
  final controller = Get.putOrFind(
    FollowSameController.new,
    tag: Get.arguments?['mid']?.toString() ?? Utils.generateRandomString(8),
  );

  @override
  PreferredSizeWidget get appBar => AppBar(
    title: Obx(
      () {
        final name = controller.name.value;
        return Text('${name == null ? '' : '我与$name的'}共同关注');
      },
    ),
  );
}

import 'package:pili_aurora/models/common/reply/reply_search_type.dart';
import 'package:pili_aurora/pages/video/reply_search_item/child/controller.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class ReplySearchController extends GetxController
    with GetSingleTickerProviderStateMixin {
  ReplySearchController(this.type, this.oid);
  final int type;
  final int oid;
  String keyword = '';

  late final FocusNode focusNode;
  late final TabController tabController;
  late final TextEditingController editingController;
  final _videoTag = Utils.generateRandomString(8);
  final _articleTag = Utils.generateRandomString(8);

  late final videoCtr = Get.put(
    ReplySearchChildController(this, ReplySearchType.video),
    tag: _videoTag,
  );
  late final articleCtr = Get.put(
    ReplySearchChildController(this, ReplySearchType.article),
    tag: _articleTag,
  );

  void onClear() {
    if (editingController.value.text.isNotEmpty) {
      editingController.clear();
      focusNode.requestFocus();
    } else {
      Get.back();
    }
  }

  @override
  void onInit() {
    super.onInit();
    focusNode = FocusNode();
    tabController = TabController(vsync: this, length: 2);
    editingController = TextEditingController();
    submit();
  }

  void submit() {
    keyword = editingController.text;
    videoCtr
      ..scrollController.jumpToTop()
      ..onReload();
    articleCtr
      ..scrollController.jumpToTop()
      ..onReload();
  }

  @override
  void onClose() {
    Get
      ..delete<ReplySearchChildController>(tag: _videoTag)
      ..delete<ReplySearchChildController>(tag: _articleTag);
    focusNode.dispose();
    tabController.dispose();
    editingController.dispose();
    super.onClose();
  }
}

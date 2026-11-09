import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_mention/group.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_mention/item.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class DynMentionController
    extends CommonListController<List<MentionGroup>?, MentionGroup> {
  final focusNode = FocusNode();
  final controller = TextEditingController();

  final RxBool enableClear = false.obs;

  final RxBool showBtn = false.obs;
  Set<MentionItem>? mentionList;

  @override
  Object get queryContext => Accounts.main;

  void updateBtn() {
    showBtn.value = mentionList?.isNotEmpty == true;
  }

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() => onReload();

  @override
  Future<void> onRefresh() {
    mentionList?.clear();
    showBtn.value = false;
    return super.onRefresh();
  }

  @override
  Future<LoadingState<List<MentionGroup>?>> customGetData() =>
      DynamicsHttp.dynMention(keyword: controller.text);

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    focusNode.dispose();
    controller.dispose();
    mentionList?.clear();
    mentionList = null;
    super.onClose();
  }

  void onCheck(bool? value, MentionItem item) {
    if (value == true) {
      (mentionList ??= <MentionItem>{}).add(item);
    } else {
      mentionList?.remove(item);
    }
    updateBtn();
  }
}

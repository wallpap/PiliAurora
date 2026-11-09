import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/models/common/later_view_type.dart';
import 'package:pili_aurora/models/common/video/source_type.dart';
import 'package:pili_aurora/models/remote/later/data.dart';
import 'package:pili_aurora/models/remote/later/list.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart'
    show CommonListController;
import 'package:pili_aurora/pages/common/multi_select/base.dart';
import 'package:pili_aurora/pages/common/multi_select/multi_select_controller.dart';
import 'package:pili_aurora/pages/later/base_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart';

mixin BaseLaterController
    on
        CommonListController<LaterData, LaterItemModel>,
        CommonMultiSelectMixin<LaterItemModel>,
        DeleteItemMixin<LaterData, LaterItemModel> {
  ValueChanged<int>? updateCount;
  final Account laterAccount = Accounts.main;
  bool _savingLater = false;

  bool get isLaterCurrent =>
      !isClosed && identical(laterAccount, Accounts.main);

  @override
  Object get queryContext => Accounts.main;

  Future<void> removeLaterItems(Set<LaterItemModel> removeList) async {
    final list = loadingState.value.dataOrNull;
    if (_savingLater || !isLaterCurrent || list == null || removeList.isEmpty) {
      return;
    }
    if (!list.toSet().containsAll(removeList) ||
        removeList.any((item) => item.aid == null)) {
      return;
    }
    _savingLater = true;
    SmartDialog.showLoading(msg: '请求中');
    try {
      final result = await UserHttp.toViewDel(
        aids: removeList.map((item) => item.aid).join(','),
        account: laterAccount,
      );
      if (!isLaterCurrent || !identical(list, loadingState.value.dataOrNull)) {
        return;
      }
      if (result.isSuccess) {
        updateCount?.call(removeList.length);
        await afterDelete(removeList);
        SmartDialog.showToast('已移除稍后再看');
      } else {
        result.toast();
      }
    } finally {
      _savingLater = false;
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  @override
  void onRemove() {
    final removeList = allChecked.toSet();
    showConfirmDialog(
      context: Get.context!,
      title: const Text('提示'),
      content: const Text('确认删除所选稍后再看吗？'),
      onConfirm: () => removeLaterItems(removeList),
    );
  }

  // single
  void toViewDel(
    BuildContext context,
    int? aid,
  ) {
    final item = loadingState.value.dataOrNull?.firstWhereOrNull(
      (item) => item.aid == aid,
    );
    if (item == null || aid == null) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('提示'),
        content: const Text('即将移除该视频，确定是否移除'),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () async {
              Get.back();
              await removeLaterItems({item});
            },
            child: const Text('确认移除'),
          ),
        ],
      ),
    );
  }
}

class LaterController extends MultiSelectController<LaterData, LaterItemModel>
    with BaseLaterController {
  LaterController(this.laterViewType);
  final LaterViewType laterViewType;

  late final mid = laterAccount.mid;

  final RxBool asc = false.obs;

  final LaterBaseController baseCtr = Get.put(LaterBaseController());

  @override
  RxBool get enableMultiSelect => baseCtr.enableMultiSelect;

  @override
  RxInt get rxCount => baseCtr.checkedCount;

  @override
  Future<LoadingState<LaterData>> customGetData() async => isLaterCurrent
      ? UserHttp.seeYouLater(
          page: page,
          viewed: laterViewType.type,
          asc: asc.value,
          account: laterAccount,
        )
      : const Error('账号已切换，请重新打开页面');

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  List<LaterItemModel>? getDataList(response) {
    baseCtr.counts[laterViewType.index] = response.count ?? 0;
    return response.list;
  }

  @override
  void checkIsEnd(int length) {
    if (length >= baseCtr.counts[laterViewType.index]) {
      isEnd = true;
    }
  }

  // 一键清空
  void toViewClear(BuildContext context, [int? cleanType]) {
    String content = switch (cleanType) {
      1 => '确定清空已失效视频吗？',
      2 => '确定清空已看完视频吗？',
      _ => '确定清空稍后再看列表吗？',
    };
    showConfirmDialog(
      context: context,
      title: const Text('确认'),
      content: Text(content),
      onConfirm: () => clearLater(cleanType: cleanType),
    );
  }

  Future<void> clearLater({int? cleanType}) async {
    if (_savingLater || !isLaterCurrent) return;
    _savingLater = true;
    try {
      final res = await UserHttp.toViewClear(
        cleanType: cleanType,
        account: laterAccount,
      );
      if (!isLaterCurrent) return;
      if (res.isSuccess) {
        onReload();
        for (final item in LaterViewType.values) {
          final tag = item.type.toString();
          if (item != laterViewType &&
              Get.isRegistered<LaterController>(tag: tag)) {
            Get.find<LaterController>(tag: tag).onReload();
          }
        }
        SmartDialog.showToast('已清空');
      } else {
        res.toast();
      }
    } finally {
      _savingLater = false;
    }
  }

  // 稍后再看播放全部
  void toViewPlayAll() {
    if (loadingState.value case Success(:final response)) {
      if (response == null || response.isEmpty) return;

      for (LaterItemModel item in response) {
        if (item.cid == null || item.pgcLabel?.isNotEmpty == true) {
          continue;
        } else {
          PageUtils.toVideoPage(
            bvid: item.bvid,
            cid: item.cid!,
            cover: item.pic,
            title: item.title,
            dimension: item.dimension,
            extraArguments: {
              'sourceType': SourceType.watchLater,
              'count': baseCtr.counts[LaterViewType.all.index],
              'favTitle': '稍后再看',
              'mediaId': mid,
              'desc': asc.value,
            },
          );
          break;
        }
      }
    }
  }

  @override
  ValueChanged<int>? get updateCount =>
      (count) => baseCtr.counts[laterViewType.index] -= count;

  @override
  Future<void> onReload() {
    scrollController.jumpToTop();
    return super.onReload();
  }
}

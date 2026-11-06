import 'package:pili_aurora/http/fan.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/remote/follow/data.dart';
import 'package:pili_aurora/models/remote/follow/list.dart';
import 'package:pili_aurora/pages/follow_type/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class FansController extends FollowTypeController {
  FansController(this.showName, {this.newFans = false});
  final bool showName;
  final bool newFans;
  late final bool isOwner;

  @override
  void init() {
    final Map? args = Get.arguments;
    final ownerMid = Accounts.main.mid;
    final int? mid = args?['mid'];
    this.mid = mid ?? ownerMid;
    isOwner = ownerMid == this.mid;
    if (showName && !isOwner) {
      final String? name = args?['name'];
      this.name = RxnString(name);
      if (name == null) {
        queryUserName();
      }
    }
    queryData();
  }

  @override
  Future<LoadingState<FollowData>> customGetData() => FanHttp.fans(
    vmid: mid,
    pn: page,
    orderType: newFans ? null : 'attention',
  );

  Future<void> onFollowBack(FollowItemModel item) async {
    final isFollowing = item.attribute == 2 || item.attribute == 6;
    final res = await VideoHttp.relationMod(
      mid: item.mid,
      act: isFollowing ? 2 : 1,
      reSrc: 107,
    );
    if (isClosed) return;
    if (res.isSuccess) {
      item.attribute = isFollowing ? 0 : 6;
      loadingState.refresh();
      SmartDialog.showToast(isFollowing ? '取消关注成功' : '回关成功');
    } else {
      await res.toast();
    }
  }

  Future<void> onRemoveFan(int index, int mid) async {
    final list = loadingState.value.data;
    final res = await VideoHttp.relationMod(
      mid: mid,
      act: 7,
      reSrc: 11,
    );
    if (isClosed || list == null || !identical(list, loadingState.value.data))
      return;
    if (res.isSuccess) {
      loadingState
        ..value.data!.removeWhere((e) => e.mid == mid)
        ..refresh();
      SmartDialog.showToast('移除成功');
    } else {
      res.toast();
    }
  }
}

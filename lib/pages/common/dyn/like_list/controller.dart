import 'package:pili_aurora/grpc/bilibili/app/dynamic/v2.pb.dart'
    show LikeListReply, ModuleAuthor;
import 'package:pili_aurora/grpc/dyn.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:get/get.dart';

class DynLikeController
    extends CommonListController<LikeListReply, ModuleAuthor> {
  DynLikeController(this.id, {int count = -1}) : count = RxInt(count);
  final String id;

  Int64? _uidOffset;
  final RxInt count;

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
  }

  void _onAccountChanged() {
    count.value = -1;
    onReload();
  }

  @override
  List<ModuleAuthor>? getDataList(LikeListReply response) {
    count.value = response.totalCount.toInt();
    final list = response.list;
    final nextOffset = list.lastOrNull?.mid;
    if (_uidOffset != null && nextOffset == _uidOffset) {
      isEnd = true;
      return const [];
    }
    if (!response.hasMore || nextOffset == null || nextOffset == _uidOffset) {
      isEnd = true;
    }
    _uidOffset = nextOffset;
    return list;
  }

  @override
  Future<LoadingState<LikeListReply>> customGetData() => DynGrpc.likeList(
    account: Accounts.main,
    dynamicId: id,
    uidOffset: _uidOffset,
    page: page,
  );

  @override
  Future<void> onRefresh() {
    _uidOffset = null;
    return super.onRefresh();
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }
}

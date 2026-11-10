import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/models/common/member/contribute_type.dart';
import 'package:pili_aurora/models/remote/space/space_archive/data.dart';
import 'package:pili_aurora/models/remote/space/space_archive/item.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:get/get.dart';

class MemberBangumiCtr
    extends CommonListController<SpaceArchiveData, SpaceArchiveItem> {
  MemberBangumiCtr({required this.mid, required this.heroTag});

  final int mid;
  final String? heroTag;
  int? count;
  int _revision = 0;
  final paginationError = Rx<Error?>(null);

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    // 父空间响应未携带可核对的账号归属，番剧页独立取得可信快照。
    queryData();
  }

  void _onAccountChanged() => onReload();

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (isRefresh) {
      _revision++;
      paginationError.value = null;
      count = null;
    }
    return super.queryData(isRefresh);
  }

  @override
  List<SpaceArchiveItem>? getDataList(SpaceArchiveData response) {
    count = response.count ?? count;
    if (response.hasNext == false) isEnd = true;
    return response.item;
  }

  @override
  void checkIsEnd(int length) {
    if (count != null && length >= count!) isEnd = true;
  }

  @override
  Future<LoadingState<SpaceArchiveData>> customGetData() async {
    final account = Accounts.main;
    final revision = _revision;
    final requestPage = page;
    var result = await MemberHttp.spaceArchive(
      account: account,
      type: ContributeType.bangumi,
      mid: mid,
      pn: requestPage,
    );
    if (result case Success(:final response)
        when response.item == null &&
            ((response.count ?? 0) > 0 || response.hasNext == true)) {
      result = const Error('番剧列表响应不完整，请重试');
    }
    if (!isClosed &&
        revision == _revision &&
        identical(account, Accounts.main)) {
      paginationError.value = requestPage > 1 && result is Error
          ? result
          : null;
    }
    return result;
  }
}

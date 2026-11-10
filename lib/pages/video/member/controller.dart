import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/models/common/member/archive_order_type_app.dart';
import 'package:pili_aurora/models/member/info.dart';
import 'package:pili_aurora/models/remote/space/space_archive/data.dart';
import 'package:pili_aurora/models/remote/space/space_archive/item.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:get/get.dart';

class HorizontalMemberPageController
    extends CommonListController<SpaceArchiveData, SpaceArchiveItem> {
  HorizontalMemberPageController({this.mid, required this.currAid});

  dynamic mid;

  final Rx<LoadingState<MemberInfoModel>> userState =
      LoadingState<MemberInfoModel>.loading().obs;
  final RxMap userStat = {}.obs;
  int _userQuery = 0;
  bool _memberClosed = false;

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    getUserInfo();
    queryData();
  }

  Future<void> getUserInfo() async {
    if (_memberClosed) return;
    final generation = ++_userQuery;
    final int target = mid;
    final account = Accounts.main;
    bool current() =>
        !_memberClosed &&
        generation == _userQuery &&
        target == mid &&
        identical(account, Accounts.main);
    userStat.clear();
    userState.value = LoadingState<MemberInfoModel>.loading();
    final res = await MemberHttp.memberInfo(mid: target, account: account);
    if (!current()) return;
    userState.value = res;
    if (res.isSuccess) {
      await _loadUserStats(account, target, current);
    }
  }

  Future<void> _loadUserStats(
    Account account,
    int target,
    bool Function() current,
  ) async {
    Future<void> apply(
      Future<LoadingState<Map<String, dynamic>>> request,
    ) async {
      final result = await request;
      if (!current()) return;
      if (result case Success(:final response)) {
        userStat.addAll(response);
      }
    }

    await Future.wait([
      apply(MemberHttp.memberStat(mid: target, account: account)),
      if (account.isLogin)
        apply(MemberHttp.memberView(mid: target, account: account)),
    ]);
  }

  @override
  void onClose() {
    _memberClosed = true;
    _userQuery++;
    super.onClose();
  }

  @override
  bool customHandleResponse(bool isRefresh, Success response) {
    SpaceArchiveData data = response.response;
    count = data.count;
    if (isRefresh) {
      if (isLoadPrevious) {
        hasPrev = data.hasPrev ?? false;
      } else {
        hasNext = data.hasNext ?? false;
      }
    }
    if (isLoadPrevious) {
      if (loadingState.value case Success(:final response)) {
        (data.item ??= <SpaceArchiveItem>[]).addAll(response!);
      }
    } else if (!isRefresh) {
      if (loadingState.value case Success(:final response)) {
        (data.item ??= <SpaceArchiveItem>[]).insertAll(0, response!);
      }
    }
    firstAid = data.item?.firstOrNull?.param;
    lastAid = data.item?.lastOrNull?.param;
    loadingState.value = Success(data.item);
    isLoadPrevious = false;
    page++;
    return true;
  }

  String? currAid;
  String? firstAid;
  String? lastAid;
  ArchiveOrderTypeApp order = .pubdate;
  int? count;
  bool isLoadPrevious = false;
  bool hasPrev = true;
  bool hasNext = true;

  @override
  Future<LoadingState<SpaceArchiveData>> customGetData() =>
      MemberHttp.spaceArchive(
        type: .video,
        mid: mid,
        aid: page == 1
            ? currAid
            : isLoadPrevious
            ? firstAid
            : lastAid,
        order: order,
        sort: page != 1 && isLoadPrevious ? .asc : null,
        pn: null,
        next: null,
        seasonId: null,
        seriesId: null,
        includeCursor: page == 1 ? true : null,
      );

  @override
  Future<void> onRefresh() {
    assert(hasPrev);
    isLoadPrevious = true;
    return queryData();
  }

  @override
  Future<void> onReload() {
    firstAid = null;
    lastAid = null;
    hasNext = true;
    hasPrev = true;
    isEnd = false;
    page = 1;
    scrollController.jumpToTop();
    return super.onReload();
  }

  void queryBySort() {
    if (isLoading) return;
    order = order == .pubdate ? .click : .pubdate;
    onReload();
  }
}

import 'dart:math';

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/member/tab_type.dart';
import 'package:pili_aurora/models/model_owner.dart';
import 'package:pili_aurora/models/remote/space/space/data.dart';
import 'package:pili_aurora/models/remote/space/space/elec.dart';
import 'package:pili_aurora/models/remote/space/space/live.dart';
import 'package:pili_aurora/models/remote/space/space/reservation_card_list.dart';
import 'package:pili_aurora/models/remote/space/space/setting.dart';
import 'package:pili_aurora/models/remote/space/space/tab2.dart';
import 'package:pili_aurora/pages/common/common_data_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/extension/nested_scroll_ext.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/share_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart'
    show ExtendedNestedScrollViewState;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class MemberController extends CommonDataController<SpaceData, SpaceData?>
    with GetTickerProviderStateMixin {
  MemberController({required this.mid});
  int mid;
  String? username;
  String? userAvatar;

  Account get account => Accounts.main;
  Object? _relationOperation;
  Object? _vipOperation;
  int _generation = 0;
  bool _closed = false;

  @override
  Object get queryContext => Accounts.main;

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (isRefresh) _generation++;
    return super.queryData(isRefresh);
  }

  void _onAccountChanged() {
    _relationOperation = _vipOperation = null;
    _resetAccountData();
    onReload();
  }

  void _resetAccountData() {
    relation.value = 0;
    isFollowed = null;
    spaceSetting = null;
    hasSeasonOrSeries = false;
    charges = null;
    chargeCount = null;
    guards = null;
    guardCount = null;
    reserves = null;
    live = null;
    silence = null;
  }

  bool _owns(Account owner, int target, int generation) =>
      !_closed &&
      !isClosed &&
      !isLoading &&
      identical(owner, account) &&
      target == mid &&
      generation == _generation;

  Future<void> Function() scopedAction(Future<void> Function() action) {
    final owner = account;
    final target = mid;
    final generation = _generation;
    return () async {
      if (_owns(owner, target, generation)) await action();
    };
  }

  Future<void> _runRelation(
    Future<void> Function(Account owner, int target, bool Function() current)
    action,
  ) async {
    if (_closed || isClosed || isLoading || _relationOperation != null) return;
    final owner = account;
    if (!owner.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    if (loadingState.value.dataOrNull == null) {
      SmartDialog.showToast('请先刷新空间信息');
      return;
    }
    final operation = _relationOperation = Object();
    final target = mid;
    final generation = _generation;
    try {
      await action(owner, target, () => _owns(owner, target, generation));
    } finally {
      if (identical(_relationOperation, operation)) _relationOperation = null;
    }
  }

  Live? live;
  int? silence;

  int? isFollowed; // 被关注
  RxInt relation = 0.obs;
  bool get isFollow {
    final relation = this.relation.value;
    return relation != 0 && relation != 128 && relation != -1;
  }

  SpaceSetting? spaceSetting;
  List<SpaceTab2>? tab2;
  late List<Tab> tabs;
  TabController? tabController;
  RxInt contributeInitialIndex = 0.obs;

  bool? hasSeasonOrSeries;

  List<ElecItem>? charges;
  int? chargeCount;
  bool get hasCharge => chargeCount != null && chargeCount! > 0;

  List<Owner>? guards;
  Object? guardCount;
  bool get hasGuard => guards?.isNotEmpty ?? false;

  List<ReservationCardItem>? reserves;

  final fromViewAid = Get.parameters['from_view_aid'];

  final scrollKey = GlobalKey<ExtendedNestedScrollViewState>();

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<SpaceData> response) {
    final data = response.response;
    final card = data.card;
    username = card?.name ?? '';
    userAvatar = card?.face;

    isFollowed = card?.relation?.isFollowed;

    // charge
    final elec = data.elec;
    charges = elec?.list;
    chargeCount = elec?.total;
    // guard
    final guard = data.guard;
    guards = guard?.item;
    guardCount = guard?.count;

    reserves = data.reservationCardList;

    switch (data.relation) {
      case -1:
        relation.value = 128;
      case -999:
        if (data.guestRelation == -1) {
          relation.value = -1;
        }
      default:
        relation.value = card?.relation?.isFollow == 1
            ? data.relSpecial == 1
                  ? -10
                  : card?.relation?.status ?? 2
            : data.relation ?? 0;
    }
    tab2 = data.tab2;
    live = data.live;
    silence = card?.silence;
    hasSeasonOrSeries =
        (data.ugcSeason?.count ?? 0) > 0 ||
        data.series?.item?.isNotEmpty == true;
    tab2?.retainWhere(
      (item) => item.param != null && MemberTabType.contains(item.param!),
    );
    if (tab2?.isNotEmpty == true) {
      if (data.hasItem != true && tab2!.first.param == 'home') {
        // remove empty home tab
        tab2!.removeAt(0);
      }
      if (tab2!.isNotEmpty) {
        int initialIndex = -1;
        MemberTabType memberTab = Pref.memberTab;
        if (memberTab != MemberTabType.def) {
          initialIndex = tab2!.indexWhere((item) {
            return item.param == memberTab.name;
          });
        }
        if (initialIndex == -1) {
          if (data.defaultTab == 'video') {
            data.defaultTab = 'contribute';
          }
          initialIndex = tab2!.indexWhere((item) {
            return item.param == data.defaultTab;
          });
        }
        tabs = tab2!
            .map(
              (item) => Tab(
                child: Text(
                  item.title ?? '',
                  softWrap: false,
                  overflow: .fade,
                ),
              ),
            )
            .toList();
        tabController?.dispose();
        tabController = TabController(
          vsync: this,
          length: tabs.length,
          initialIndex: max(0, initialIndex),
        );
      }
    }
    spaceSetting = mid == account.mid ? data.setting : null;
    loadingState.value = response;
    return true;
  }

  @override
  bool handleError(String? errMsg) {
    _resetAccountData();
    tab2 = const [
      SpaceTab2(title: '动态', param: 'dynamic'),
      SpaceTab2(
        title: '投稿',
        param: 'contribute',
        items: [SpaceTab2Item(title: '视频', param: 'video')],
      ),
      SpaceTab2(title: '收藏', param: 'favorite'),
      SpaceTab2(title: '追番', param: 'bangumi'),
    ];
    tabs = tab2!.map((item) => Tab(text: item.title)).toList();
    tabController?.dispose();
    tabController = TabController(
      vsync: this,
      length: tabs.length,
    );
    username = errMsg;
    loadingState.value = const Success(null);
    return true;
  }

  @override
  Future<LoadingState<SpaceData>> customGetData() => MemberHttp.space(
    account: account,
    mid: mid,
    fromViewAid: fromViewAid,
  );

  Future<void> blockUser(BuildContext context) =>
      _runRelation((owner, target, current) async {
        if (target == owner.mid || !context.mounted) return;
        final wasBlocked = relation.value == 128;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('提示'),
            content: Text(wasBlocked ? '从黑名单移除UP主' : '确定拉黑UP主?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('点错了'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('确认'),
              ),
            ],
          ),
        );
        if (confirmed == true && current()) {
          await _onBlock(owner, target, wasBlocked, current);
        }
      });

  void shareUser() {
    ShareUtils.shareText('https://space.bilibili.com/$mid');
  }

  Future<void> _onBlock(
    Account owner,
    int target,
    bool wasBlocked,
    bool Function() current,
  ) async {
    final result = await VideoHttp.relationMod(
      account: owner,
      mid: target,
      act: wasBlocked ? 6 : 5,
      reSrc: 11,
    );
    if (!current()) return;
    if (result.isSuccess) {
      relation.value = wasBlocked ? 0 : 128;
    } else {
      result.toast();
      if (result is UnknownResult) await onReload();
    }
  }

  Future<void> onFollow(BuildContext context) =>
      _runRelation((owner, target, current) async {
        if (!context.mounted) return;
        if (target == owner.mid) {
          Get.toNamed('/editProfile');
        } else if (relation.value == 128) {
          await _onBlock(owner, target, true, current);
        } else {
          await RequestUtils.actionRelationMod(
            context: context,
            account: owner,
            mid: target,
            isFollow: isFollow,
            isCurrent: current,
            afterMod: (attribute) {
              if (current()) relation.value = attribute;
            },
          );
        }
      });

  @override
  void onClose() {
    _closed = true;
    _generation++;
    Accounts.mainChanges.removeListener(_onAccountChanged);
    tabController?.dispose();
    super.onClose();
  }

  Future<void> onRemoveFan() => _runRelation((owner, target, current) async {
    if (owner.mid == target || isFollowed != 1) return;
    final result = await VideoHttp.relationMod(
      account: owner,
      mid: target,
      act: 7,
      reSrc: 11,
    );
    if (!current()) return;
    if (result.isSuccess) {
      isFollowed = null;
      if (relation.value == 4) relation.value = 2;
      loadingState.refresh();
      SmartDialog.showToast('移除成功');
    } else {
      result.toast();
      if (result is UnknownResult) await onReload();
    }
  });

  void onTapTab(int value) {
    if (tabController?.indexIsChanging == false) {
      scrollKey.currentState?.animToTop();
    }
  }

  Future<void> vipExpAdd() async {
    final owner = account;
    if (_closed ||
        isClosed ||
        isLoading ||
        _vipOperation != null ||
        !owner.isLogin ||
        owner.mid != mid ||
        loadingState.value.dataOrNull == null) {
      return;
    }
    final operation = _vipOperation = Object();
    final target = mid;
    final generation = _generation;
    try {
      final result = await UserHttp.vipExpAdd(account: owner);
      if (!_owns(owner, target, generation)) return;
      if (result.isSuccess) {
        SmartDialog.showToast('领取成功');
      } else {
        result.toast();
      }
    } finally {
      if (identical(_vipOperation, operation)) _vipOperation = null;
    }
  }
}

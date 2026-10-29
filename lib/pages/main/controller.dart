import 'dart:async';
import 'dart:math' as math;

import 'package:pili_aurora/common/widgets/view_safe_area.dart';
import 'package:pili_aurora/grpc/dyn.dart';
import 'package:pili_aurora/models/common/dynamic/dynamic_badge_mode.dart';
import 'package:pili_aurora/models/common/home_tab_type.dart';
import 'package:pili_aurora/models/common/msg/msg_unread_type.dart';
import 'package:pili_aurora/models/common/nav_bar_config.dart';
import 'package:pili_aurora/pages/dynamics/controller.dart';
import 'package:pili_aurora/pages/home/controller.dart';
import 'package:pili_aurora/pages/mine/view.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/services/messaging/overview.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/utils/extension/get_ext.dart';
import 'package:pili_aurora/utils/extension/iterable_ext.dart';
import 'package:pili_aurora/utils/feed_back.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/update.dart';
import 'package:pili_aurora/utils/rate_limiter.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class MainController extends GetxController
    with GetSingleTickerProviderStateMixin, AccountMixin {
  @override
  final AccountService accountService = Get.find<AccountService>();

  List<NavigationBarType> navigationBars = <NavigationBarType>[];

  RxDouble? barOffset;
  RxBool? showBottomBar;
  late final bool hideBottomBar;
  late final barHideType = Pref.barHideType;
  bool useBottomNav = false;
  late dynamic controller;
  final RxInt selectedIndex = 0.obs;
  late final VoidCallback _unregisterPageDiagnostics;

  final RxInt dynCount = 0.obs;
  late DynamicBadgeMode dynamicBadgeMode;
  late bool checkDynamic = Pref.checkDynamic;
  late int dynamicPeriod = Pref.dynamicPeriod * 60 * 1000;
  late int _lastCheckDynamicAt = 0;
  late bool hasDyn = false;
  late final dynamicController = Get.putOrFind(DynamicsController.new);

  late bool hasHome = false;
  late final homeController = Get.putOrFind(HomeController.new);

  late DynamicBadgeMode msgBadgeMode = Pref.msgBadgeMode;
  late Set<MsgUnReadType> msgUnReadTypes = Pref.msgUnReadTypeV2;
  final msgBadgeRevision = 0.obs;
  late int lastCheckUnreadAt = 0;

  final enableMYBar = Pref.enableMYBar;
  final floatingNavBar = Pref.floatingNavBar;
  final useSideBar = Pref.useSideBar;
  final mainTabBarView = Pref.mainTabBarView;
  late final optTabletNav = Pref.optTabletNav;

  late bool directExitOnBack = Pref.directExitOnBack;
  late bool showTrayIcon = Pref.showTrayIcon;
  late bool minimizeOnExit = Pref.minimizeOnExit;
  late bool pauseOnMinimize = Pref.pauseOnMinimize;
  late bool isPlaying = false;

  static const _period = 5 * 60 * 1000;
  late int _lastSelectTime = 0;

  late bool _shouldCheckUpdate;
  late bool _shouldCheckDynamic;
  late bool _shouldCheckMessages;

  @override
  void onInit() {
    super.onInit();
    _shouldCheckUpdate = Pref.autoUpdate;

    setNavBarConfig();
    _unregisterPageDiagnostics = Diagnostics.instance.register(
      'mainPage',
      () => {
        'page': navigationBars[selectedIndex.value].name,
      },
    );

    controller = mainTabBarView
        ? TabController(
            vsync: this,
            initialIndex: selectedIndex.value,
            length: navigationBars.length,
          )
        : PageController(initialPage: selectedIndex.value);

    hideBottomBar =
        !useSideBar && navigationBars.length > 1 && Pref.hideBottomBar;
    if (hideBottomBar) {
      switch (barHideType) {
        case .instant:
          showBottomBar = RxBool(true);
        case .sync:
          barOffset ??= RxDouble(0.0);
      }
    }

    dynamicBadgeMode = Pref.dynamicBadgeMode;

    hasDyn = navigationBars.contains(NavigationBarType.dynamics);
    _shouldCheckDynamic =
        dynamicBadgeMode != DynamicBadgeMode.hidden &&
        hasDyn &&
        navigationBars[selectedIndex.value] != .dynamics;
    if (_shouldCheckDynamic && checkDynamic) {
      _lastCheckDynamicAt = DateTime.now().millisecondsSinceEpoch;
    }

    hasHome = navigationBars.contains(NavigationBarType.home);
    _shouldCheckMessages = msgBadgeMode != DynamicBadgeMode.hidden && hasHome;
    if (_shouldCheckMessages) {
      lastCheckUnreadAt = DateTime.now().millisecondsSinceEpoch;
    }
  }

  @override
  void onReady() {
    super.onReady();
    if (isClosed) return;

    // 未读数与更新提示不参与首屏布局，改在 GetX 的首帧后生命周期中发起，
    // 避免启动阶段争用 Dart/UI 线程和网络资源。
    if (_shouldCheckUpdate) unawaited(Update.checkUpdate());
    if (_shouldCheckDynamic) getUnreadDynamic();
    if (_shouldCheckMessages) unawaited(queryUnreadMsg());
  }

  void updateMessageBadge() => msgBadgeRevision.value++;

  Future<void> queryUnreadMsg([bool isChangeType = false]) async {
    updateMessageBadge();
    if (!accountService.isLogin.value ||
        !hasHome ||
        msgUnReadTypes.isEmpty ||
        msgBadgeMode == DynamicBadgeMode.hidden) {
      return;
    }
    await overviewFor(Messaging.instance.session).refresh();
  }

  void getUnreadDynamic() {
    if (!accountService.isLogin.value || !hasDyn) {
      return;
    }
    DynGrpc.dynRed().then((res) {
      if (res != null) {
        setDynCount(res);
      }
    });
  }

  void setDynCount([int count = 0]) {
    if (!hasDyn) return;
    dynCount.value = count;
  }

  void checkUnreadDynamic() {
    if (!hasDyn ||
        !accountService.isLogin.value ||
        dynamicBadgeMode == DynamicBadgeMode.hidden ||
        !checkDynamic) {
      return;
    }
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastCheckDynamicAt >= dynamicPeriod) {
      _lastCheckDynamicAt = now;
      getUnreadDynamic();
    }
  }

  void setNavBarConfig() {
    List<int>? navBarSort =
        (GStorage.setting.get(SettingBoxKey.navBarSort) as List?)?.fromCast();
    late final List<NavigationBarType> navigationBars;
    if (navBarSort == null || navBarSort.isEmpty) {
      navigationBars = NavigationBarType.values;
    } else {
      navigationBars = navBarSort
          .map(NavigationBarType.values.elementAt)
          .toList();
    }
    this.navigationBars = navigationBars;
    final defPage = Pref.defaultHomePage;
    selectedIndex.value = math.max(0, navigationBars.indexOf(defPage));
  }

  void checkDefaultSearch([bool shouldCheck = false]) {
    if (hasHome && homeController.enableSearchWord) {
      if (shouldCheck &&
          navigationBars[selectedIndex.value] != NavigationBarType.home) {
        return;
      }
      int now = DateTime.now().millisecondsSinceEpoch;
      if (now - homeController.lateCheckSearchAt >= _period) {
        homeController
          ..lateCheckSearchAt = now
          ..querySearchDefault();
      }
    }
  }

  void checkUnread([bool shouldCheck = false]) {
    if (accountService.isLogin.value &&
        hasHome &&
        msgBadgeMode != DynamicBadgeMode.hidden) {
      if (shouldCheck &&
          navigationBars[selectedIndex.value] != NavigationBarType.home) {
        return;
      }
      int now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastCheckUnreadAt >= _period) {
        lastCheckUnreadAt = now;
        queryUnreadMsg();
      }
    }
  }

  int? _mineIndex;
  void toMinePage() {
    _mineIndex ??= navigationBars.indexOf(NavigationBarType.mine);
    if (_mineIndex != -1) {
      setIndex(_mineIndex!);
    } else {
      Get.to(
        const Material(
          child: ViewSafeArea(
            top: true,
            child: MinePage(showBackBtn: true),
          ),
        ),
      );
    }
  }

  void setIndex(int value) {
    feedBack();

    final currentNav = navigationBars[value];
    if (value != selectedIndex.value) {
      selectedIndex.value = value;
      Diagnostics.instance.log(
        DiagnosticLogLevel.debug,
        'pageSwitch',
        '切换主页面',
        details: {'page': currentNav.name},
      );
      if (mainTabBarView) {
        controller.animateTo(value);
      } else {
        controller.jumpToPage(value);
      }
      if (currentNav == NavigationBarType.home) {
        checkDefaultSearch();
        checkUnread();
      } else if (currentNav == NavigationBarType.dynamics) {
        setDynCount();
      }
    } else {
      int now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastSelectTime < 500) {
        ActionThrottle.run(
          'topOrRefresh',
          const Duration(milliseconds: 500),
          () {
            if (currentNav == NavigationBarType.home) {
              homeController.onRefresh();
            } else if (currentNav == NavigationBarType.dynamics) {
              dynamicController.onRefresh();
            }
          },
        );
      } else {
        if (currentNav == NavigationBarType.home) {
          homeController.toTopOrRefresh();
        } else if (currentNav == NavigationBarType.dynamics) {
          dynamicController.toTopOrRefresh();
        }
      }
      _lastSelectTime = now;
    }
  }

  void setSearchBar() {
    if (hasHome) {
      homeController.showTopBar?.value = true;
    }
  }

  bool refreshRecommendations() {
    if (navigationBars[selectedIndex.value] == NavigationBarType.home &&
        homeController.tabs[homeController.tabController.index] ==
            HomeTabType.rcmd) {
      homeController.onRefresh();
      return true;
    }
    return false;
  }

  @override
  void onClose() {
    _unregisterPageDiagnostics();
    barOffset?.close();
    controller.dispose();
    super.onClose();
  }

  @override
  void onChangeAccount(bool isLogin) {
    if (isLogin) {
      queryUnreadMsg();
      getUnreadDynamic();
    } else {
      setDynCount();
    }
  }
}

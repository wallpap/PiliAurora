import 'dart:async' show FutureOr, unawaited;
import 'dart:math';

import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/common/widgets/dialog/simple_dialog_option.dart';
import 'package:pili_aurora/common/widgets/selection_text.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/http/validate.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/models/login/gaia_result.dart';
import 'package:pili_aurora/models/remote/fav/fav_detail/media.dart';
import 'package:pili_aurora/models/remote/later/list.dart';
import 'package:pili_aurora/models/remote/relation/data.dart';
import 'package:pili_aurora/pages/common/multi_select/base.dart';
import 'package:pili_aurora/pages/dynamics_tab/controller.dart';
import 'package:pili_aurora/pages/later/controller.dart'
    show BaseLaterController;
import 'package:pili_aurora/pages/fav_detail/controller.dart'
    show BaseFavController;
import 'package:pili_aurora/pages/group_panel/view.dart';
import 'package:pili_aurora/pages/login/geetest/geetest_webview_dialog.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/extension/context_ext.dart';
import 'package:pili_aurora/utils/extension/size_ext.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';
import 'package:pili_aurora/utils/extension/theme_ext.dart';
import 'package:pili_aurora/utils/feed_back.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/navigation_request.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract final class RequestUtils {
  static Future<void> addToWatchLater({String? bvid, Object? aid}) async {
    final account = Accounts.main;
    final result = await UserHttp.toViewLater(
      bvid: bvid,
      aid: aid,
      account: account,
    );
    if (!identical(account, Accounts.main)) return;
    if (result.isSuccess) {
      SmartDialog.showToast('已添加到稍后再看');
    } else {
      result.toast();
    }
  }

  static int _historyStatusGeneration = 0;
  static Future<void> syncHistoryStatus() async {
    final generation = ++_historyStatusGeneration;
    final account = Accounts.history;
    if (!account.isLogin) {
      return;
    }
    final res = await UserHttp.historyStatus(account: account);
    if (generation != _historyStatusGeneration ||
        !identical(account, Accounts.history)) {
      return;
    }
    if (res case Success(:final response)) {
      await GStorage.localCache.put(LocalCacheKey.historyPause, response);
    }
  }

  static Future<void> actionRelationMod({
    required BuildContext context,
    Account? account,
    required dynamic mid,
    required bool isFollow,
    required ValueChanged<int>? afterMod,
    RelationData? followStatus,
    bool Function()? isCurrent,
  }) async {
    final requestAccount = account ?? Accounts.main;
    bool current() =>
        context.mounted &&
        identical(requestAccount, Accounts.main) &&
        (isCurrent?.call() ?? true);
    if (mid == null || !current()) {
      return;
    }
    void notify(int attribute) {
      try {
        afterMod?.call(attribute);
      } catch (error, stackTrace) {
        logger.w(
          '关系已更新，本地回调失败',
          error: error.runtimeType,
          stackTrace: stackTrace,
        );
      }
    }

    feedBack();
    if (!isFollow) {
      final res = await VideoHttp.relationMod(
        account: requestAccount,
        mid: mid,
        act: 1,
        reSrc: 11,
      );
      if (!current()) return;
      if (res.isSuccess) {
        SmartDialog.showToast('关注成功');
        notify(2);
      } else {
        res.toast();
      }
    } else {
      if (followStatus?.tag == null) {
        final res = await UserHttp.userRelation(mid, account: requestAccount);
        if (!current()) return;
        if (res case Success(:final response)) {
          followStatus = response;
        } else {
          res.toast();
          return;
        }
      }

      if (context.mounted && current()) {
        bool isSpecialFollowed = followStatus!.special == 1;
        String text = isSpecialFollowed ? '移除特别关注' : '加入特别关注';
        Future<void>? pendingAction;
        void runAction(Future<void> Function() action) {
          pendingAction ??= action();
        }

        await showDialog<void>(
          context: context,
          builder: (dialogContext) => SimpleDialog(
            clipBehavior: Clip.hardEdge,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              DialogOption(
                onPressed: () => runAction(() async {
                  Get.back();
                  if (!current()) return;
                  final res = await MemberHttp.specialAction(
                    account: requestAccount,
                    fid: mid,
                    isAdd: !isSpecialFollowed,
                  );
                  if (!current()) return;
                  if (res.isSuccess) {
                    SmartDialog.showToast('$text成功');
                    notify(isSpecialFollowed ? 2 : -10);
                  } else {
                    res.toast();
                  }
                }),
                child: Text(text, style: const TextStyle(fontSize: 14)),
              ),
              DialogOption(
                onPressed: () => runAction(() async {
                  Get.back();
                  if (!current()) return;
                  final result = await showModalBottomSheet<Set<int>>(
                    context: context,
                    useSafeArea: true,
                    isScrollControlled: true,
                    constraints: BoxConstraints(
                      maxWidth: min(640, context.mediaQueryShortestSide),
                    ),
                    builder: (BuildContext context) {
                      final maxChildSize =
                          PlatformUtils.isMobile &&
                              !context.mediaQuerySize.isPortrait
                          ? 1.0
                          : 0.7;
                      return DraggableScrollableSheet(
                        minChildSize: 0,
                        maxChildSize: 1,
                        snap: true,
                        expand: false,
                        snapSizes: [maxChildSize],
                        initialChildSize: maxChildSize,
                        builder: (context, scrollController) {
                          return GroupPanel(
                            mid: mid,
                            account: requestAccount,
                            tags: followStatus!.tag,
                            scrollController: scrollController,
                          );
                        },
                      );
                    },
                  );
                  if (current() && result != null) {
                    followStatus!.tag = result.toList();
                    notify(result.contains(-10) ? -10 : 2);
                  }
                }),
                child: const Text('设置分组', style: TextStyle(fontSize: 14)),
              ),
              DialogOption(
                onPressed: () => runAction(() async {
                  Get.back();
                  if (!current()) return;
                  final res = await VideoHttp.relationMod(
                    account: requestAccount,
                    mid: mid,
                    act: 2,
                    reSrc: 11,
                  );
                  if (!current()) return;
                  if (res.isSuccess) {
                    SmartDialog.showToast('取消关注成功');
                    notify(0);
                  } else {
                    res.toast();
                  }
                }),
                child: const Text('取消关注', style: TextStyle(fontSize: 14)),
              ),
            ],
          ),
        );
        await pendingAction;
      }
    }
  }

  static ReplyInfo replyCast(Map res) {
    Map? emote = res['content']['emote'];
    emote?.forEach((key, value) {
      value['size'] = value['meta']['size'];
    });
    return ReplyInfo.create()..mergeFromProto3Json(
      res
        ..['content'].remove('members')
        ..['id'] = res['rpid']
        ..['member']['name'] = res['member']['uname']
        ..['member']['face'] = res['member']['avatar']
        ..['member']['level'] = res['member']['level_info']['current_level']
        ..['member']['vipStatus'] = res['member']['vip']['vipStatus']
        ..['member']['vipType'] = res['member']['vip']['vipType']
        ..['member']['officialVerifyType'] =
            res['member']['official_verify']['type']
        ..['content']['emotes'] = emote,
      ignoreUnknownFields: true,
    );
  }

  static Future<void> insertCreatedDyn(Object? id, {Account? account}) async {
    account ??= Accounts.main;
    if (id == null || !Get.isRegistered<DynamicsTabController>(tag: 'all')) {
      return;
    }
    final controller = Get.find<DynamicsTabController>(tag: 'all');
    final list = controller.loadingState.value.dataOrNull;
    try {
      await Future.pause(const Duration(milliseconds: 450));
      if (controller.isClosed || !identical(account, Accounts.main)) return;
      final result = await DynamicsHttp.dynamicDetail(id: id, account: account);
      if (controller.isClosed ||
          !identical(account, Accounts.main) ||
          !identical(list, controller.loadingState.value.dataOrNull)) {
        return;
      }
      if (result case Success(:final response)) {
        if (list == null) return;
        list
          ..removeWhere((item) => item.idStr.toString() == id.toString())
          ..insert(0, response);
        controller.loadingState.refresh();
      }
    } catch (error, stackTrace) {
      logger.w('动态发布后的列表刷新失败', error: error, stackTrace: stackTrace);
    }
  }

  static Future<void> checkCreatedDyn({
    dynamic id,
    String? dynText,
    bool isManual = false,
    Account? account,
  }) async {
    account ??= Accounts.main;
    bool isCurrent() =>
        identical(account, Accounts.main) && Get.context?.mounted == true;
    if (isManual || Pref.enableCreateDynAntifraud) {
      try {
        if (id != null) {
          if (!isManual) {
            await Future.pause(const Duration(seconds: 5));
          }
          if (!isCurrent()) return;
          final res = await DynamicsHttp.dynamicDetail(
            id: id,
            clearCookie: true,
          );
          if (!isCurrent()) return;
          if (res is Error) {
            SmartDialog.showToast('暂时无法确认动态可见性：$res');
            return;
          }
          final isSuccess = res.data.visible != false;
          showDialog(
            context: Get.context!,
            barrierDismissible: isManual,
            builder: (context) {
              final colorScheme = ColorScheme.of(context);
              final color = isSuccess ? colorScheme.primary : colorScheme.error;
              final actions = [
                if (!isSuccess)
                  TextButton(
                    onPressed: () {
                      Get.back();
                      Utils.copyText('https://www.bilibili.com/opus/$id');
                      Get.toNamed(
                        '/webview',
                        parameters: {
                          'url':
                              'https://www.bilibili.com/h5/comment/appeal?${ThemeUtils.themeUrl(colorScheme.isDark)}',
                        },
                      );
                    },
                    child: const Text('申诉'),
                  ),
                if (!isManual)
                  TextButton(
                    onPressed: Get.back,
                    child: Text(
                      '关闭',
                      style: TextStyle(color: colorScheme.outline),
                    ),
                  ),
              ];
              return AlertDialog(
                title: Text.rich(
                  TextSpan(
                    children: [
                      WidgetSpan(
                        alignment: .middle,
                        child: isSuccess
                            ? Icon(
                                size: 22,
                                color: color,
                                Icons.check_circle_outline_rounded,
                              )
                            : Icon(
                                size: 22,
                                color: color,
                                Icons.highlight_off_outlined,
                              ),
                      ),
                      TextSpan(
                        text: ' 动态检查结果',
                        style: TextStyle(color: color),
                      ),
                    ],
                  ),
                ),
                content: SelectionText(
                  '${isSuccess ? '未登录状态下可以查看该动态。' : '未登录状态下无法查看该动态，请检查可见范围。'}${dynText != null ? ' \n\n动态内容: $dynText' : ''}',
                ),
                actions: actions.isEmpty ? null : actions,
              );
            },
          );
        }
      } catch (e, stackTrace) {
        logger.w('check dyn error: $e', error: e, stackTrace: stackTrace);
      }
    }
  }

  static final _likingDynamics = <DynamicItemModel>{};

  // 同一动态共用在途状态，避免列表与详情入口重复写入。
  static Future<void> onLikeDynamic(
    DynamicItemModel item,
    bool uiStatus,
    VoidCallback onSuccess, {
    BuildContext? context,
  }) async {
    if (!_likingDynamics.add(item)) return;
    final account = Accounts.main;
    final dynamicId = item.idStr?.toString();
    final like = item.modules.moduleStat?.like;
    final status = like?.status ?? false;
    feedBack();
    try {
      if (status ^ uiStatus) {
        SmartDialog.showToast(status ? '点赞成功' : '取消赞');
        onSuccess();
        return;
      }
      if (dynamicId == null || dynamicId.isEmpty) {
        SmartDialog.showToast('动态缺少 ID，请刷新后重试');
        return;
      }
      final result = await DynamicsHttp.thumbDynamic(
        account: account,
        dynamicId: dynamicId,
        up: status ? 2 : 1,
      );
      if (!identical(account, Accounts.main) ||
          context?.mounted == false ||
          item.idStr.toString() != dynamicId ||
          !identical(like, item.modules.moduleStat?.like)) {
        return;
      }
      if (result.isSuccess) {
        SmartDialog.showToast(status ? '取消赞' : '点赞成功');
        if (like != null) {
          if (like.count case final count?) {
            like.count = max(0, count + (status ? -1 : 1));
          }
          like.status = !status;
        }
        onSuccess();
      } else {
        result.toast();
      }
    } finally {
      _likingDynamics.remove(item);
    }
  }

  static Future<void> onCopyOrMove<T extends MultiSelectData>({
    required BuildContext context,
    required bool isCopy,
    required CommonMultiSelectMixin<T> ctr,
    required dynamic mediaId,
    required dynamic mid,
  }) async {
    final account = switch (ctr) {
      BaseFavController controller => controller.account,
      BaseLaterController controller => controller.laterAccount,
      _ => Accounts.main,
    };
    final source = ctr.loadingState.value.dataOrNull;
    if (source == null) return;
    final removeList = ctr.allChecked.toSet();
    if (removeList.isEmpty) return;
    bool current() =>
        context.mounted &&
        identical(account, Accounts.main) &&
        identical(source, ctr.loadingState.value.dataOrNull) &&
        (ctr is! GetxController || !(ctr as GetxController).isClosed);
    if (!current()) return;
    final result = await FavHttp.allFavFolders(mid, account: account);
    if (!context.mounted || !current()) return;
    if (result case Success(:final response)) {
      final list = response.list;
      if (list == null || list.isEmpty) {
        SmartDialog.showToast('暂无可用收藏夹，请先创建');
        return;
      }
      int? checkedId;
      var saving = false;
      final isFav = ctr is BaseFavController;
      final resources = (isFav ? removeList.toList().reversed : removeList)
          .map(
            (item) => switch (item) {
              LaterItemModel(:final aid?) => aid,
              FavDetailItemModel(id: final id?, type: final type?) =>
                '$id:$type',
              _ => null,
            },
          )
          .toList();
      if (resources.contains(null)) {
        SmartDialog.showToast('所选内容缺少有效标识');
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text('${isCopy ? '复制' : '移动'}到'),
            contentPadding: const EdgeInsets.only(top: 5),
            content: SingleChildScrollView(
              child: RadioGroup<int>(
                onChanged: (value) {
                  if (!saving) setState(() => checkedId = value);
                },
                groupValue: checkedId,
                child: Column(
                  children: list
                      .map(
                        (item) => RadioListTile<int>(
                          dense: true,
                          title: Text(item.title),
                          value: item.id,
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: saving || checkedId == null
                    ? null
                    : () async {
                        if (!current()) return;
                        setState(() => saving = true);
                        try {
                          final result = await FavHttp.copyOrMoveFav(
                            account: account,
                            isCopy: isCopy,
                            isFav: isFav,
                            srcMediaId: mediaId,
                            tarMediaId: checkedId,
                            resources: resources.join(','),
                            mid: isCopy ? mid : null,
                          );
                          if (!current() ||
                              !dialogContext.mounted ||
                              ModalRoute.of(dialogContext)?.isCurrent != true) {
                            return;
                          }
                          if (result.isSuccess) {
                            if (!isCopy) {
                              final before = source.length;
                              source.removeWhere(removeList.contains);
                              final removed = before - source.length;
                              switch (ctr) {
                                case BaseFavController controller:
                                  controller.updateCount?.call(removed);
                                case BaseLaterController controller:
                                  controller.updateCount?.call(removed);
                              }
                              ctr.loadingState.refresh();
                            }
                            ctr.handleSelect(checked: false);
                            SmartDialog.showToast('${isCopy ? '复制' : '移动'}成功');
                            Navigator.of(dialogContext).pop();
                          } else {
                            result.toast();
                          }
                        } finally {
                          if (context.mounted) setState(() => saving = false);
                        }
                      },
                child: Text(saving ? '提交中' : '确认'),
              ),
            ],
          ),
        ),
      );
    } else {
      result.toast();
    }
  }

  static Future<void> validate(
    String vVoucher,
    FutureOr<void> Function(String) onSuccess, {
    required Account account,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return;
    final res = await ValidateHttp.gaiaVgateRegister(
      vVoucher,
      account: account,
    );
    if (!isCurrent()) return;
    if (!res.isSuccess) {
      if (res is UnknownResult) {
        SmartDialog.showToast('验证响应未能确认，请重新打开验证');
      } else {
        res.toast();
      }
      return;
    }

    final registration = res.data;
    final Map<String, dynamic>? json;
    try {
      json = await GeetestWebviewDialog.geetest(
        registration.gt,
        registration.challenge,
      );
    } catch (error, stackTrace) {
      logger.w('打开风控验证失败', error: error.runtimeType, stackTrace: stackTrace);
      if (isCurrent()) SmartDialog.showToast('无法打开验证，请重试');
      return;
    }
    if (!isCurrent() || json == null) return;
    final challenge = json['geetest_challenge'];
    final seccode = json['geetest_seccode'];
    final validate = json['geetest_validate'];
    if (challenge is! String ||
        seccode is! String ||
        validate is! String ||
        [challenge, seccode, validate].any((value) => value.trim().isEmpty)) {
      SmartDialog.showToast('验证结果不完整，请重新打开验证');
      return;
    }
    final result = await ValidateHttp.gaiaVgateValidate(
      account: account,
      challenge: challenge,
      seccode: seccode,
      token: registration.token,
      validate: validate,
    );
    if (!isCurrent()) return;
    switch (result) {
      case Success(response: GaiaVerified(:final riskId)):
        await onSuccess(riskId);
      case Success(response: GaiaRejected()):
        SmartDialog.showToast('验证未通过，请重试');
      case UnknownResult():
        SmartDialog.showToast('验证响应未能确认，请重新打开验证');
      case Error():
        result.toast();
      case Loading():
        break;
    }
  }

  static Future<void> showUserRealName(String mid) async {
    final request = NavigationRequest();
    final account = Accounts.main;
    bool current() => request.isCurrent && identical(account, Accounts.main);
    try {
      final res = await UserHttp.getUserRealName(mid, account: account);
      if (!current() || Get.context?.mounted != true) return;
      if (res case Success(:final response)) {
        final show = !response.name.isNullOrEmpty;
        final dialog = showDialog<void>(
          context: Get.context!,
          builder: (context) => AlertDialog(
            title: SelectionText(
              show ? response.name! : response.rejectPage?.title ?? '',
            ),
            content: show ? null : Text(response.rejectPage?.text ?? ''),
            actions: [
              TextButton(
                onPressed: () {
                  if (ModalRoute.of(context)?.isCurrent == true) {
                    Navigator.of(context).pop();
                  }
                },
                child: const Text('关闭'),
              ),
            ],
          ),
        );
        unawaited(
          dialog.then(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              logger.w(
                '实名信息弹窗失败',
                error: error.runtimeType,
                stackTrace: stackTrace,
              );
            },
          ),
        );
      } else {
        res.toast();
      }
    } catch (error, stackTrace) {
      logger.w('实名信息查询失败', error: error.runtimeType, stackTrace: stackTrace);
      if (current()) SmartDialog.showToast('实名信息查询失败，请重试');
    } finally {
      await request.close();
    }
  }
}

import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/common/widgets/selection_text.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/reply.dart';
import 'package:pili_aurora/models/common/reply/reply_sort_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/android/android_helper.dart';
import 'package:pili_aurora/utils/extension/theme_ext.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 自动检查在发布页关闭后交付给原评论页；离开来源后不再交付迟到结果。
final class _ReplyCheck with RouteAware {
  _ReplyCheck(Route<dynamic>? route, this.ownerIsCurrent)
    : route = route ?? Get.routing.route {
    if (this.route case final GetPageRoute route) {
      routeObserver.subscribe(this, route);
    }
  }

  final Route<dynamic>? route;
  final bool Function()? ownerIsCurrent;
  final Account account = Accounts.main;
  bool _cancelled = false;
  bool ownsDialog = false;

  bool get isValid =>
      !_cancelled &&
      identical(account, Accounts.main) &&
      (ownerIsCurrent?.call() ?? true) &&
      (route?.isActive ?? true) &&
      Get.context?.mounted == true;

  bool get isCurrent => isValid && (route?.isCurrent ?? true);

  @override
  void didPushNext() => _cancelled = true;

  @override
  void didPop() => _cancelled = true;

  void dispose() {
    _cancelled = true;
    routeObserver.unsubscribe(this);
  }
}

abstract final class ReplyUtils {
  static Future<void> onCheckReply({
    required ReplyInfo replyInfo,
    required bool biliSendCommAntifraud,
    required sourceId,
    required bool isManual,
    Route<dynamic>? sourceRoute,
    bool Function()? ownerIsCurrent,
  }) async {
    final check = _ReplyCheck(sourceRoute, ownerIsCurrent);
    try {
      await _checkReply(
        check: check,
        oid: replyInfo.oid.toInt(),
        type: replyInfo.type.toInt(),
        id: replyInfo.id.toInt(),
        message: replyInfo.content.message,
        //
        root: replyInfo.root.toInt(),
        parent: replyInfo.parent.toInt(),
        ctime: replyInfo.ctime.toInt(),
        pictures: replyInfo.content.pictures
            .map((item) => item.toProto3Json())
            .toList(),
        mid: replyInfo.mid.toInt(),
        //
        isManual: isManual,
        biliSendCommAntifraud: biliSendCommAntifraud,
        sourceId: sourceId,
      );
    } catch (error, stackTrace) {
      final failure = Error.fromException(error, stackTrace);
      if (check.isCurrent) failure.toast();
    } finally {
      if (!check.ownsDialog) check.dispose();
    }
  }

  // ref https://github.com/freedom-introvert/biliSendCommAntifraud
  static Future<void> _checkReply({
    required _ReplyCheck check,
    required int oid,
    required int type,
    required int id,
    required String message,
    required int root,
    required int parent,
    required int ctime,
    required List pictures,
    required int mid,
    bool isManual = false,
    required bool biliSendCommAntifraud,
    required sourceId,
  }) async {
    final account = check.account;
    bool isCurrent() => check.isCurrent;
    if (!check.isValid) return;
    // biliSendCommAntifraud
    if (Platform.isAndroid && biliSendCommAntifraud) {
      try {
        final cookieString = account.cookieJar
            .toJson()
            .entries
            .map((i) => '${i.key}=${i.value}')
            .join(';');
        PiliAndroidHelper.biliSendCommAntifraud(
          0,
          oid,
          type,
          id,
          root,
          parent,
          ctime,
          message,
          pictures,
          sourceId,
          mid,
          cookieString,
        );
      } catch (e, stackTrace) {
        logger.w(
          '调用评论检查助手失败',
          error: e.runtimeType,
          stackTrace: stackTrace,
        );
      }
      return;
    }

    // CommAntifraud
    if (!isManual) {
      await Future.pause(const Duration(seconds: 8));
    }
    if (!isCurrent()) return;
    void showReplyCheckResult(String message, {bool isBan = false}) {
      if (!isCurrent()) return;
      final dialog = showDialog<void>(
        context: Get.context!,
        barrierDismissible: isManual,
        builder: (context) {
          final dialogRoute = ModalRoute.of(context);
          final navigator = Navigator.of(context);
          final colorScheme = ColorScheme.of(context);
          final color = isBan ? colorScheme.error : colorScheme.primary;
          final actions = [
            if (isBan)
              TextButton(
                onPressed: () {
                  if (dialogRoute?.isCurrent != true) return;
                  final canAppeal = check.isValid;
                  navigator.pop();
                  if (!canAppeal) return;
                  String? uri;
                  switch (type) {
                    case 1:
                      uri = IdUtils.av2bv(oid);
                    case 17:
                      uri = 'https://www.bilibili.com/opus/$oid';
                  }
                  if (uri != null) {
                    Utils.copyText(uri);
                  }
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
                onPressed: () {
                  if (dialogRoute?.isCurrent == true) navigator.pop();
                },
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
                    child: isBan
                        ? Icon(
                            size: 22,
                            color: color,
                            Icons.highlight_off_outlined,
                          )
                        : Icon(
                            size: 22,
                            color: color,
                            Icons.check_circle_outline_rounded,
                          ),
                  ),
                  TextSpan(
                    text: ' 评论检查结果',
                    style: TextStyle(color: color),
                  ),
                ],
              ),
            ),
            content: SelectionText(message),
            actions: actions.isEmpty ? null : actions,
          );
        },
      );
      check.ownsDialog = true;
      // Future 表示查询已交付；弹窗自己的完成负责释放路由观察者。
      unawaited(
        dialog.then(
          (_) => check.dispose(),
          onError: (Object error, StackTrace stackTrace) {
            check.dispose();
            logger.w(
              '评论检查弹窗失败',
              error: error.runtimeType,
              stackTrace: stackTrace,
            );
          },
        ),
      );
    }

    // root reply
    if (root == 0) {
      // no cookie check
      final res = await ReplyHttp.replyList(
        isLogin: false,
        oid: oid,
        nextOffset: '',
        type: type,
        sort: ReplySortType.time.index,
        page: 1,
      );
      if (!isCurrent()) return;

      if (res is Error) {
        SmartDialog.showToast('获取评论主列表时发生错误：$res');
        return;
      } else if (res case Success(:final response)) {
        final index =
            response.replies?.indexWhere((item) => item.rpid == id) ?? -1;
        if (index != -1) {
          // found
          showReplyCheckResult('无账号状态下找到了你的评论，评论正常！\n\n你的评论：$message');
        } else {
          // not found

          // cookie check
          final res1 = await ReplyHttp.replyReplyList(
            account: account,
            isLogin: true,
            oid: oid,
            root: id,
            pageNum: 1,
            type: type,
          );
          if (!isCurrent()) return;

          if (res1 is Error) {
            if (res1.code != 12022) {
              SmartDialog.showToast('评论检查失败：$res1');
              return;
            }
            // not found
            showReplyCheckResult('无法找到你的评论。\n\n你的评论：$message', isBan: true);
          } else {
            // found

            // no cookie check
            final res2 = await ReplyHttp.replyReplyList(
              isLogin: false,
              oid: oid,
              root: id,
              pageNum: 1,
              type: type,
            );
            if (!isCurrent()) return;

            if (res2 is Error) {
              if (res2.code != 12022) {
                SmartDialog.showToast('评论检查失败：$res2');
                return;
              }
              // not found
              showReplyCheckResult(
                '你的评论被shadow ban（仅自己可见）！\n\n你的评论: $message',
                isBan: true,
              );
            } else {
              // found
              showReplyCheckResult(
                isManual
                    ? '无账号状态下找到了你的评论，评论正常！\n\n你的评论：$message'
                    : '''
你评论状态有点可疑，虽然无账号翻找评论区获取不到你的评论，但是无账号可通过
https://api.bilibili.com/x/v2/reply/reply?oid=$oid&pn=1&ps=20&root=$id&type=$type
获取你的评论，疑似评论区被戒严或者这是你的视频。

你的评论：$message''',
              );
            }
          }
        }
      }
    } else {
      Future<LoadingState<bool>> containsReply({required bool isLogin}) async {
        final seen = <int?>{};
        for (var page = 1; page <= 100; page++) {
          final result = await ReplyHttp.replyReplyList(
            account: account,
            isLogin: isLogin,
            oid: oid,
            root: root,
            pageNum: page,
            type: type,
          );
          if (!isCurrent()) return const Error('评论检查已失效');
          if (result is Error) {
            return result.code == 12022 ? const Success(false) : result;
          }
          final data = result.data;
          final replies = data.replies;
          if (replies == null || replies.isEmpty) return const Success(false);
          if (replies.any((item) => item.rpid == id)) {
            return const Success(true);
          }
          final before = seen.length;
          seen.addAll(replies.map((item) => item.rpid));
          if (seen.length == before || seen.contains(null)) {
            return const Error('评论列表未能继续加载，暂时无法确认评论状态');
          }
          final count = data.page?.count;
          final size = data.page?.size;
          if (count != null &&
              size != null &&
              size > 0 &&
              page * size >= count) {
            return const Success(false);
          }
        }
        return const Error('评论列表超出检查上限，请稍后重试');
      }

      final anonymous = await containsReply(isLogin: false);
      if (!isCurrent()) return;
      if (anonymous is Error) {
        SmartDialog.showToast('评论检查失败：$anonymous');
        return;
      }
      if (anonymous.data) {
        showReplyCheckResult('无账号状态下找到了你的评论，评论正常！\n\n你的评论：$message');
        return;
      }
      final loggedIn = await containsReply(isLogin: true);
      if (!isCurrent()) return;
      if (loggedIn is Error) {
        SmartDialog.showToast('评论检查失败：$loggedIn');
        return;
      }
      if (loggedIn.data) {
        showReplyCheckResult(
          '你的评论被shadow ban（仅自己可见）！\n\n你的评论: $message',
          isBan: true,
        );
        return;
      }

      showReplyCheckResult('评论不可见: $message', isBan: true);
    }
  }
}

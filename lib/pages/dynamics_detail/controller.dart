import 'dart:async';

import 'package:pili_aurora/common/widgets/scroll_physics.dart'
    show ReloadMixin;
import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/reply.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/pages/common/dyn/common_dyn_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class DynamicDetailController extends CommonDynController with ReloadMixin {
  DynamicDetailController({super.count});

  @override
  late int oid;
  @override
  late int replyType;
  late DynamicItemModel dynItem;
  bool _changingReplySubject = false;

  @override
  dynamic get sourceId => replyType == 1 ? IdUtils.av2bv(oid) : oid;

  @override
  void onInit() {
    super.onInit();
    dynItem = Get.arguments['item'];
    final commentType = dynItem.basic?.commentType;
    final commentIdStr = dynItem.basic?.commentIdStr;
    if (commentType != null &&
        commentType != 0 &&
        commentIdStr != null &&
        commentIdStr.isNotEmpty) {
      _init(commentIdStr, commentType);
    } else {
      DynamicsHttp.dynamicDetail(id: dynItem.idStr).then((res) {
        if (res case Success(:final response)) {
          _init(response.basic!.commentIdStr!, response.basic!.commentType!);
        } else {
          res.toast();
        }
      });
    }
  }

  void _init(String commentIdStr, int commentType) {
    oid = int.parse(commentIdStr);
    replyType = commentType;
    queryData();
  }

  Future<LoadingState> onSetPubSetting(bool isPrivate, Object dynId) async {
    final res = await DynamicsHttp.dynPrivatePubSetting(
      dynId: dynId,
      action: isPrivate ? 'public_pub' : 'private_pub',
    );
    if (res.isSuccess) {
      dynItem.modules.moduleAuthor?.badgeText = isPrivate ? null : '仅自己可见';
      SmartDialog.showToast('设置成功');
    } else {
      res.toast();
    }
    return res;
  }

  Future<void> onSetReplySubject(int action) async {
    if (_changingReplySubject) return;
    _changingReplySubject = true;
    final account = Accounts.main;
    final item = dynItem;
    final oid = this.oid;
    final type = replyType;
    try {
      final res = await ReplyHttp.replySubjectModify(
        account: account,
        oid: oid,
        type: type,
        action: action,
      );
      if (isClosed ||
          !identical(account, Accounts.main) ||
          !identical(item, dynItem) ||
          oid != this.oid ||
          type != replyType) {
        return;
      }
      if (res case Success(:final response)) {
        SmartDialog.showToast(
          response?.trim().isNotEmpty == true ? response! : '设置成功',
        );
        Timer(const Duration(milliseconds: 500), () {
          if (!isClosed &&
              identical(account, Accounts.main) &&
              identical(item, dynItem) &&
              oid == this.oid &&
              type == replyType) {
            onReload();
          }
        });
      } else {
        res.toast();
      }
    } finally {
      _changingReplySubject = false;
    }
  }

  @override
  Future<void> onReload() {
    reload = true;
    return super.onReload();
  }
}

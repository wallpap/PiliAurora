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
  int oid = 0;
  @override
  int replyType = 0;
  late DynamicItemModel dynItem;
  bool _changingReplySubject = false;
  bool _changingVisibility = false;
  bool _loadingSource = false;
  bool _sourceReady = false;

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
      _loadCommentSource();
    }
  }

  Future<void> _loadCommentSource() async {
    if (isClosed || _loadingSource) return;
    _loadingSource = true;
    final item = dynItem;
    final account = Accounts.heartbeat;
    try {
      final result = await DynamicsHttp.dynamicDetail(
        id: item.idStr,
        account: account,
      );
      if (isClosed ||
          !identical(item, dynItem) ||
          !identical(account, Accounts.heartbeat)) {
        return;
      }
      if (result case Success(:final response)) {
        _init(response.basic?.commentIdStr, response.basic?.commentType);
      } else if (result is Error) {
        loadingState.value = result;
      }
    } finally {
      _loadingSource = false;
    }
  }

  void _init(String? commentIdStr, int? commentType) {
    final id = int.tryParse(commentIdStr ?? '');
    if (id == null || id <= 0 || commentType == null || commentType <= 0) {
      loadingState.value = const Error('动态缺少有效的评论来源，请重试');
      return;
    }
    oid = id;
    replyType = commentType;
    _sourceReady = true;
    queryData();
  }

  Future<LoadingState<void>> onSetPubSetting(
    bool isPrivate,
    Object dynId,
  ) async {
    if (isClosed) return const Error('页面已关闭');
    if (_changingVisibility) return const Error('正在设置可见范围，请稍候');
    final account = Accounts.main;
    final item = dynItem;
    if (dynId.toString() != item.idStr.toString()) {
      return const Error('动态已变更，请重试');
    }
    _changingVisibility = true;
    try {
      final result = await DynamicsHttp.dynPrivatePubSetting(
        account: account,
        dynId: dynId,
        action: isPrivate ? 'public_pub' : 'private_pub',
      );
      if (isClosed ||
          !identical(account, Accounts.main) ||
          !identical(item, dynItem)) {
        return const Error('账号或动态已变更');
      }
      if (result.isSuccess) {
        item.modules.moduleAuthor?.badgeText = isPrivate ? null : '仅自己可见';
        SmartDialog.showToast('设置成功');
      } else {
        result.toast();
      }
      return result;
    } finally {
      _changingVisibility = false;
    }
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
    return _sourceReady ? super.onReload() : _loadCommentSource();
  }
}

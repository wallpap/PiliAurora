import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/sponsor_block.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/navigation_request.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

/// 描述链接的查询、确认和写入由同一次页面操作持有。
class UgcDescriptionLinkAction {
  UgcDescriptionLinkAction({Future<void> Function(String)? openLink})
    : _openLink = openLink ?? PageUtils.handleWebview;

  final Future<void> Function(String) _openLink;
  bool _running = false;

  static final youtubeRegExp = RegExp(
    r'(?:youtube\.com\/(?:[^\/\n\s]+\/\S+\/|(?:v|e(?:mbed)?)\/|\S*?[?&]v=)|youtu\.be\/)([a-z0-9_\-]{11})',
    caseSensitive: false,
  );

  Future<void> run({
    required BuildContext context,
    required String url,
    required String bvid,
    required int cid,
    required int duration,
    required bool enableSponsorBlock,
    required bool Function() isCurrent,
  }) async {
    if (_running || !context.mounted || !isCurrent()) return;
    _running = true;
    final request = NavigationRequest();
    final account = Accounts.main;
    bool current() =>
        context.mounted &&
        request.isCurrent &&
        identical(account, Accounts.main) &&
        isCurrent();
    try {
      final ytbId = youtubeRegExp.firstMatch(url)?.group(1);
      if (enableSponsorBlock && duration > 0 && ytbId != null) {
        final server = Pref.blockServer;
        final userId = Pref.blockUserID;
        bool bindingCurrent() =>
            current() &&
            Pref.blockServer == server &&
            Pref.blockUserID == userId;
        final LoadingState<String> port;
        request.showLoading();
        try {
          port = await SponsorBlock.getPortVideo(bvid: bvid, cid: cid);
        } finally {
          await request.closeLoading();
        }
        if (!context.mounted || !bindingCurrent()) return;
        // 只有明确的 404 代表未绑定，查询失败保留现有绑定。
        if (port is! Success<String> && !(port is Error && port.code == 404)) {
          port.toast();
          await _openLink(url);
          return;
        }
        final alreadyBound = port.dataOrNull == ytbId;
        final confirmed = await showConfirmDialog(
          context: context,
          title: const Text('空降助手：搬运视频同步'),
          content: Text(
            '${alreadyBound ? "" : "是否将"}该视频${alreadyBound ? "已" : ""}绑定到此YouTube视频($ytbId)',
          ),
        );
        if (!bindingCurrent()) return;
        if (!alreadyBound && confirmed) {
          final result = await SponsorBlock.postPortVideo(
            bvid: bvid,
            cid: cid,
            ytbId: ytbId,
            videoDuration: (duration / 1000).round(),
          );
          if (!bindingCurrent()) return;
          if (result.isSuccess) {
            SmartDialog.showToast('提交搬运视频成功');
          } else {
            result.toast();
          }
          return;
        }
      }
      if (current()) await _openLink(url);
    } catch (error, stackTrace) {
      logger.w('打开视频描述链接失败', error: error.runtimeType, stackTrace: stackTrace);
      if (current()) SmartDialog.showToast('链接暂时无法打开，请重试');
    } finally {
      await request.close();
      _running = false;
    }
  }
}

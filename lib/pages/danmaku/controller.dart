import 'dart:collection';
import 'dart:io' show File;

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/danmaku/cache.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:path/path.dart' as path;

class PlDanmakuController {
  PlDanmakuController(
    this._cid,
    this._plPlayerController,
    this._isFileSource,
  ) : _mergeDanmaku = _plPlayerController.mergeDanmaku;

  final int _cid;
  final PlPlayerController _plPlayerController;
  final bool _mergeDanmaku;
  final bool _isFileSource;

  late final _isLogin = Accounts.main.isLogin;

  final _cache = DanmakuCache();
  // 请求中的分段单独记录；成功加载后由缓存记录，淘汰后允许重新请求。
  final Set<int> _requestedSeg = HashSet();
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _cache.clear();
    _requestedSeg.clear();
  }

  Future<void> queryDanmaku(int segmentIndex) async {
    if (_isFileSource || _disposed) {
      return;
    }
    if (_requestedSeg.contains(segmentIndex) ||
        _cache.containsSegment(segmentIndex)) {
      return;
    }
    _requestedSeg.add(segmentIndex);
    late final LoadingState<DmSegMobileReply> res;
    try {
      res = await DmGrpc.dmSegMobile(
        cid: _cid,
        segmentIndex: segmentIndex + 1,
      );
    } finally {
      _requestedSeg.remove(segmentIndex);
    }
    if (_disposed) return;

    if (res case Success(:final response)) {
      if (response.state == 1) {
        _plPlayerController.dmState.add(_cid);
      }
      handleDanmaku(response.elems, segmentIndex: segmentIndex);
    }
  }

  void handleDanmaku(List<DanmakuElem> elems, {int? segmentIndex}) {
    if (_disposed) return;
    final uniques = HashMap<String, DanmakuElem>();
    final retained = _isFileSource ? <DanmakuElem>[] : null;
    final segmentBuckets = segmentIndex == null
        ? null
        : <int, List<DanmakuElem>>{};
    final maxElementsPerBucket = _cache.maxElementsPerBucket;

    final filters = _plPlayerController.filters;
    final shouldFilter = filters.count != 0;
    for (final element in elems) {
      final bucketIndex = element.progress ~/ 100;
      if (!_isFileSource &&
          (segmentIndex == null ||
              DmUtils.calcSegment(element.progress) != segmentIndex)) {
        continue;
      }
      if (!_isFileSource &&
          (segmentBuckets![bucketIndex]?.length ?? 0) >= maxElementsPerBucket) {
        if (_mergeDanmaku) {
          uniques[element.content]?.count++;
        }
        continue;
      }

      if (_isLogin) {
        element.isSelf = element.midHash == _plPlayerController.midHash;
      }

      if (!element.isSelf) {
        if (_mergeDanmaku) {
          final elem = uniques[element.content];
          if (elem == null) {
            uniques[element.content] = element..count = 1;
          } else {
            elem.count++;
            continue;
          }
        }

        if (shouldFilter && filters.remove(element)) {
          continue;
        }
      }

      if (_isFileSource) {
        retained!.add(element);
      } else {
        (segmentBuckets![bucketIndex] ??= <DanmakuElem>[]).add(element);
      }
    }
    if (_isFileSource) {
      // 本地文件无法回源，保留完整弹幕。
      _cache.addFileElements(retained!);
    } else if (segmentIndex != null) {
      _cache.addSegmentBuckets(segmentIndex, segmentBuckets!);
    }
  }

  List<DanmakuElem>? getCurrentDanmaku(int progress) {
    if (_isFileSource) {
      initFileDmIfNeeded();
    } else {
      final int segmentIndex = DmUtils.calcSegment(progress);
      if (!_requestedSeg.contains(segmentIndex) &&
          !_cache.containsSegment(segmentIndex)) {
        queryDanmaku(segmentIndex);
        return null;
      }
    }
    return _cache.getAt(progress);
  }

  bool _fileDmLoaded = false;

  void initFileDmIfNeeded() {
    if (_fileDmLoaded) return;
    _fileDmLoaded = true;
    _initFileDm();
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> _initFileDm() async {
    try {
      final file = File(
        path.join(
          (_plPlayerController.dataSource as FileSource).dir,
          PathUtils.danmakuName,
        ),
      );
      if (!file.existsSync()) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;
      final elem = DmSegMobileReply.fromBuffer(bytes).elems;
      handleDanmaku(elem);
    } catch (e, s) {
      Utils.reportError(e, s);
    }
  }
}

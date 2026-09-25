import 'dart:collection';
import 'dart:io' show File;

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/loading_state.dart';
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

  // 100 毫秒分桶便于播放，但长视频不能一直保留所有分桶。
  static const _maxCachedBuckets = 6000;
  static const _maxCachedElements = 30000;
  final Map<int, List<DanmakuElem>> _dmSegMap = {};
  final Map<int, int> _segmentBucketCounts = HashMap();
  int _cachedElementCount = 0;
  int? _lastAccessedBucket;
  // 已请求的段落标记
  late final Set<int> _requestedSeg = HashSet();

  void dispose() {
    _dmSegMap.clear();
    _segmentBucketCounts.clear();
    _cachedElementCount = 0;
    _lastAccessedBucket = null;
    _requestedSeg.clear();
  }

  void _trimCache() {
    // 本地弹幕没有网络回源能力，保留完整数据以支持回退播放。
    if (_isFileSource) return;

    while (_dmSegMap.length > _maxCachedBuckets ||
        _cachedElementCount > _maxCachedElements) {
      final bucket = _dmSegMap.keys.first;
      final elements = _dmSegMap.remove(bucket);
      _cachedElementCount -= elements?.length ?? 0;

      final segment = DmUtils.calcSegment(bucket * 100);
      final count = _segmentBucketCounts[segment];
      if (count == null || count <= 1) {
        _segmentBucketCounts.remove(segment);
        // 淘汰后允许回退播放时重新请求该分段。
        _requestedSeg.remove(segment);
      } else {
        _segmentBucketCounts[segment] = count - 1;
      }
    }
  }

  Future<void> queryDanmaku(int segmentIndex) async {
    if (_isFileSource) {
      return;
    }
    if (_requestedSeg.contains(segmentIndex)) {
      return;
    }
    _requestedSeg.add(segmentIndex);
    final res = await DmGrpc.dmSegMobile(
      cid: _cid,
      segmentIndex: segmentIndex + 1,
    );

    if (res case Success(:final response)) {
      if (response.state == 1) {
        _plPlayerController.dmState.add(_cid);
      }
      handleDanmaku(response.elems);
    } else {
      _requestedSeg.remove(segmentIndex);
    }
  }

  void handleDanmaku(List<DanmakuElem> elems) {
    if (elems.isEmpty) return;
    final uniques = HashMap<String, DanmakuElem>();

    final filters = _plPlayerController.filters;
    final shouldFilter = filters.count != 0;
    for (final element in elems) {
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

      final int pos = element.progress ~/ 100; //每0.1秒存储一次
      final bucket = _dmSegMap[pos];
      if (bucket == null) {
        _dmSegMap[pos] = [element];
        final segment = DmUtils.calcSegment(pos * 100);
        _segmentBucketCounts[segment] =
            (_segmentBucketCounts[segment] ?? 0) + 1;
      } else {
        bucket.add(element);
      }
      _cachedElementCount++;
    }
    _trimCache();
  }

  List<DanmakuElem>? getCurrentDanmaku(int progress) {
    if (_isFileSource) {
      initFileDmIfNeeded();
    } else {
      final int segmentIndex = DmUtils.calcSegment(progress);
      if (!_requestedSeg.contains(segmentIndex)) {
        queryDanmaku(segmentIndex);
        return null;
      }
    }
    final bucket = progress ~/ 100;
    final result = _dmSegMap[bucket];
    if (result != null && bucket != _lastAccessedBucket) {
      // 保留最近显示的分桶，回退播放时优先命中缓存。
      _dmSegMap
        ..remove(bucket)
        ..[bucket] = result;
      _lastAccessedBucket = bucket;
    }
    return result;
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

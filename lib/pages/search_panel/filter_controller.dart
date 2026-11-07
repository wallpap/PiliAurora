import 'package:pili_aurora/models/common/search/article_search_type.dart';
import 'package:pili_aurora/models/common/search/search_type.dart';
import 'package:pili_aurora/models/common/search/user_search_type.dart';
import 'package:pili_aurora/models/common/search/video_search_type.dart';
import 'package:pili_aurora/models/search/result.dart';
import 'package:pili_aurora/pages/search_panel/controller.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

/// 仅持有页面筛选表单；查询、结果和分页由 Riverpod 管理。
class SearchPanelController<R extends SearchNumData<T>, T> {
  SearchPanelController({
    required this.keyword,
    required this.searchType,
    required this.tag,
  });
  final Object tag;
  final String keyword;
  final SearchType searchType;
  String order = '';
  VideoDurationType? videoDurationType;
  VideoZoneType? videoZoneType;
  int? pubBegin;
  int? pubEnd;
  UserOrderType? userOrderType;
  UserType? userType;
  ArticleZoneType? articleZoneType;
  bool isClosed = false;
  void Function()? reload;
  SearchResultsState? results;
  void onInit() {}
  void dispose() {
    isClosed = true;
    reload = null;
    results = null;
  }

  void onResults(SearchResultsState data) {}
  Map<String, dynamic> get filters => {
    'order': order,
    'duration': ?videoDurationType?.index,
    'tids': ?videoZoneType?.tids,
    'orderSort': ?userOrderType?.orderSort,
    'userType': ?userType?.index,
    'categoryId': ?articleZoneType?.categoryId,
    'pubBegin': ?pubBegin,
    'pubEnd': ?pubEnd,
    'filtered':
        order.isNotEmpty ||
        (videoDurationType != null &&
            videoDurationType != VideoDurationType.all) ||
        (videoZoneType != null && videoZoneType != VideoZoneType.all) ||
        pubBegin != null ||
        pubEnd != null,
  };
  void onSortSearch({bool getBack = true, String? label}) {
    if (isClosed) return;
    if (getBack) Get.back();
    if (label != null) SmartDialog.showToast('「$label」的筛选结果');
    reload?.call();
  }
}

import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/space/space_fav/data.dart';
import 'package:pili_aurora/models/remote/space/space_fav/list.dart';
import 'package:pili_aurora/pages/common/common_data_controller.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class MemberFavoriteCtr
    extends CommonDataController<List<SpaceFavData>?, List<SpaceFavData>?> {
  MemberFavoriteCtr({
    required this.mid,
  });

  final int mid;
  int _folderGeneration = 0;
  Object? _favLoad;
  Object? _subLoad;
  bool _foldersReady = true;

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (isRefresh) {
      _folderGeneration++;
      _favLoad = _subLoad = null;
      _foldersReady = false;
      favPage = subPage = 2;
    }
    return super.queryData(isRefresh);
  }

  @override
  void onClose() {
    _folderGeneration++;
    _foldersReady = false;
    super.onClose();
  }

  late int favPage = 2;
  bool _favExpand = true;
  final RxBool favEnd = true.obs;
  final Rx<SpaceFavData> favState = SpaceFavData().obs;

  late int subPage = 2;
  bool _subExpand = true;
  final RxBool subEnd = true.obs;
  final Rx<SpaceFavData> subState = SpaceFavData().obs;

  bool isExpand(bool isFav) {
    return isFav ? _favExpand : _subExpand;
  }

  void setExpand(bool isFav) {
    if (isFav) {
      flag = _favExpand;
      _favExpand = !_favExpand;
    } else {
      _subExpand = !_subExpand;
    }
  }

  bool flag = false;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  Future<void> onRefresh() {
    favPage = 2;
    subPage = 2;
    return super.onRefresh();
  }

  @override
  bool customHandleResponse(
    bool isRefresh,
    Success<List<SpaceFavData>?> response,
  ) {
    try {
      List<SpaceFavData> res = response.response!;
      _foldersReady = true;
      favState.value = res.first;
      subState.value = res[1];

      favEnd.value =
          (res.first.mediaListResponse?.count ?? -1) <=
          (res.first.mediaListResponse?.list?.length ?? -1);
      subEnd.value =
          (res[1].mediaListResponse?.count ?? -1) <=
          (res[1].mediaListResponse?.list?.length ?? -1);
    } catch (e, stackTrace) {
      logger.w(e.toString(), error: e, stackTrace: stackTrace);
    }
    loadingState.value = response;
    return true;
  }

  Future<void> userFavFolder() async {
    if (isClosed || !_foldersReady || _favLoad != null || favEnd.value) return;
    final operation = _favLoad = Object();
    final generation = _folderGeneration;
    final snapshot = favState.value;
    try {
      final res = await Request().get(
        Api.userFavFolder,
        queryParameters: {
          'pn': favPage,
          'ps': 20,
          'up_mid': mid,
        },
      );
      if (isClosed ||
          generation != _folderGeneration ||
          !identical(snapshot, favState.value)) {
        return;
      }
      if (res.data['code'] == 0) {
        favPage++;
        final data = res.data['data'];
        if (data != null) {
          favEnd.value = data['has_more'] == false;
          final list = (data['list'] as List<dynamic>?)
              ?.map((item) => SpaceFavItemModel.fromJson(item))
              .toList();
          if (list != null && list.isNotEmpty) {
            favState
              ..value.mediaListResponse!.list!.addAll(
                list.where(
                  (item) => !snapshot.mediaListResponse!.list!.any(
                    (existing) => existing.id == item.id,
                  ),
                ),
              )
              ..refresh();
          } else {
            favEnd.value = true;
          }
        } else {
          favEnd.value = true;
        }
      } else {
        SmartDialog.showToast(res.data['message']);
      }
    } catch (e) {
      if (!isClosed && generation == _folderGeneration) {
        SmartDialog.showToast(e.toString());
      }
    } finally {
      if (identical(_favLoad, operation)) _favLoad = null;
    }
  }

  Future<void> userSubFolder() async {
    if (isClosed || !_foldersReady || _subLoad != null || subEnd.value) return;
    final operation = _subLoad = Object();
    final generation = _folderGeneration;
    final snapshot = subState.value;
    try {
      final res = await Request().get(
        Api.userSubFolder,
        queryParameters: {
          'up_mid': mid,
          'ps': 20,
          'pn': subPage,
          'platform': 'web',
        },
      );
      if (isClosed ||
          generation != _folderGeneration ||
          !identical(snapshot, subState.value)) {
        return;
      }
      if (res.data['code'] == 0) {
        subPage++;
        final data = res.data['data'];
        if (data != null) {
          subEnd.value = data['has_more'] == false;
          final list = (data['list'] as List<dynamic>?)
              ?.map((item) => SpaceFavItemModel.fromJson(item))
              .toList();
          if (list != null && list.isNotEmpty) {
            subState
              ..value.mediaListResponse!.list!.addAll(
                list.where(
                  (item) => !snapshot.mediaListResponse!.list!.any(
                    (existing) => existing.id == item.id,
                  ),
                ),
              )
              ..refresh();
          } else {
            subEnd.value = true;
          }
        } else {
          subEnd.value = true;
        }
      } else {
        SmartDialog.showToast(res.data['message']);
      }
    } catch (e) {
      if (!isClosed && generation == _folderGeneration) {
        SmartDialog.showToast(e.toString());
      }
    } finally {
      if (identical(_subLoad, operation)) _subLoad = null;
    }
  }

  @override
  Future<LoadingState<List<SpaceFavData>?>> customGetData() =>
      FavHttp.spaceFav(mid: mid);
}

import 'dart:math' show max;

import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/image_preview_type.dart';
import 'package:pili_aurora/models/dynamics/article_content_model.dart'
    show ArticleContentModel;
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/models/model_avatar.dart';
import 'package:pili_aurora/models/remote/article/article_view/data.dart';
import 'package:pili_aurora/pages/common/dyn/common_dyn_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/app_scheme.dart';
import 'package:pili_aurora/utils/extension/get_ext.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/url_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

typedef _ArticleContext = ({
  Account account,
  int version,
  String id,
  String type,
});

class ArticleController extends CommonDynController {
  late String id;
  late String type;

  String get url => type == 'read'
      ? 'https://www.bilibili.com/read/cv$id'
      : 'https://www.bilibili.com/opus/$id';
  int commentId = 0;
  @override
  int get oid => commentId;
  int commentType = 12;
  @override
  int get replyType => commentType;
  final summary = Summary();

  late final RxInt topIndex = 0.obs;

  @override
  dynamic get sourceId => commentType == 12 ? 'cv$commentId' : id;

  bool _contentLoading = false;
  bool _initialized = false;
  int _contentVersion = 0;
  int _infoVersion = 0;
  Object? _favoriteOperation;
  Object? _likeOperation;
  final RxBool isLoaded = false.obs;
  DynamicItemModel? opusData; // 标题信息从summary获取, 动态没有favorite
  ArticleViewData? articleData;
  final stats = Rxn<ModuleStatModel>();

  List<ArticleContentModel>? get opus =>
      opusData?.modules.moduleContent ?? articleData?.opus?.content;

  List<SourceModel>? _images;
  List<SourceModel> images() => _images ??= [
    for (final paragraph in opus ?? <ArticleContentModel>[])
      if (paragraph.paraType == 2)
        if (paragraph.pic?.pics?.firstOrNull?.url case final url?
            when url.isNotEmpty)
          SourceModel(url: url),
  ];

  @override
  Object get queryContext => Accounts.main;

  _ArticleContext get _context => (
    account: Accounts.main,
    version: _contentVersion,
    id: id,
    type: type,
  );

  bool _owns(_ArticleContext context) =>
      !isClosed &&
      identical(context.account, Accounts.main) &&
      context.version == _contentVersion &&
      context.id == id &&
      context.type == type;

  @override
  void onInit() {
    super.onInit();
    final params = Get.parameters;
    id = params['id']!;
    type = params['type']!;

    // to opus
    if (type == 'read') {
      final originalId = id;
      UrlUtils.parseRedirectUrl('https://www.bilibili.com/read/cv$id/').then((
        url,
      ) {
        if (isClosed || id != originalId || type != 'read') return;
        if (url != null) {
          final opusId = PiliScheme.uriDigitRegExp.firstMatch(url)?.group(1);
          if (opusId != null) {
            id = opusId;
            type = 'opus';
          }
          Get.putOrFind(() => this, tag: type + id);
        }
        init();
      });
    } else {
      init();
    }
  }

  @override
  void onAccountChanged() {
    savedReplies.clear();
    count.value = -1;
    _contentVersion++;
    _infoVersion++;
    _contentLoading = false;
    _favoriteOperation = _likeOperation = null;
    isLoaded.value = false;
    opusData = null;
    articleData = null;
    _images = null;
    stats.value = null;
    summary
      ..author = null
      ..title = null
      ..cover = null;
    showTitle.value = false;
    loadingState.value = LoadingState.loading();
    if (_initialized) _queryContent();
  }

  void init() {
    if (isClosed) return;
    commentType = type == 'picture' ? 11 : 12;
    _initialized = true;
    if ((int.tryParse(id) ?? 0) <= 0) {
      loadingState.value = const Error('文章地址无效，请重新打开');
      return;
    }
    _queryContent();
  }

  Future<bool> queryOpus(String opusId) async {
    final context = _context;
    final res = await DynamicsHttp.opusDetail(
      account: context.account,
      opusId: opusId,
    );
    if (!_owns(context)) return false;
    if (res case Success(:final response)) {
      //fallback
      if (response.fallback?.id != null) {
        final articleId = int.tryParse(response.fallback!.id!);
        if (articleId == null || articleId <= 0) {
          loadingState.value = const Error('文章缺少有效编号，请重试');
          return false;
        }
        id = response.fallback!.id!;
        type = 'read';
        commentId = articleId;
        commentType = 12;
        return queryRead(commentId);
      }
      if (response.idStr != null && response.idStr.toString() != opusId) {
        loadingState.value = const Error('文章与请求目标不符，请重试');
        return false;
      }
      opusData = response;
      articleData = null;
      _images = null;
      commentType = response.basic!.commentType!;
      commentId = int.parse(response.basic!.commentIdStr!);
      if (showDynActionBar) {
        if (response.modules.moduleStat != null) {
          stats.value = response.modules.moduleStat;
        } else {
          getArticleInfo();
        }
      }
      summary
        ..author ??= response.modules.moduleAuthor
        ..title ??= response.modules.moduleTag?.text;
      return true;
    } else {
      loadingState.value = res as Error;
      return false;
    }
  }

  Future<bool> queryRead(int cvid) async {
    final context = _context;
    final res = await DynamicsHttp.articleView(
      account: context.account,
      cvId: cvid,
    );
    if (!_owns(context)) return false;
    if (res case Success(:final response)) {
      if (response.id != null && response.id != cvid) {
        loadingState.value = const Error('文章与请求目标不符，请重试');
        return false;
      }
      articleData = response;
      opusData = null;
      _images = null;
      summary
        ..author ??= response.author
        ..title ??= response.title
        ..cover ??= response.originImageUrls?.firstOrNull;

      if (showDynActionBar) {
        getArticleInfo();
      }
      return true;
    } else {
      loadingState.value = res as Error;
      return false;
    }
  }

  // stats
  Future<bool> getArticleInfo([bool isGetCover = false]) async {
    final context = _context;
    final articleId = commentId;
    final version = ++_infoVersion;
    final res = await DynamicsHttp.articleInfo(
      account: context.account,
      cvId: articleId,
    );
    if (!_owns(context) || version != _infoVersion || articleId != commentId) {
      return false;
    }
    if (res case Success(:final response)) {
      summary
        ..cover ??= response.originImageUrls?.firstOrNull
        ..title ??= response.title;

      stats.value ??= ModuleStatModel(
        comment: DynamicStat(count: response.stats?.reply),
        forward: DynamicStat(count: response.stats?.share),
        like: DynamicStat(
          count: response.stats?.like,
          status: response.like,
        ),
        favorite: DynamicStat(
          count: response.stats?.favorite,
          status: response.favorite,
        ),
      );
      return true;
    }
    if (isGetCover) {
      res.toast();
    }
    return false;
  }

  // 请求动态内容
  Future<void> _queryContent() async {
    if (isClosed || _contentLoading) return;
    _contentLoading = true;
    final version = ++_contentVersion;
    final account = Accounts.main;
    final heartbeat = Accounts.heartbeat;
    try {
      final bool loaded;
      if (type != 'read') {
        loaded = await queryOpus(id);
      } else {
        final articleId = int.tryParse(id);
        if (articleId == null || articleId <= 0) {
          loadingState.value = const Error('文章地址无效，请重新打开');
          return;
        }
        commentId = articleId;
        commentType = 12;
        loaded = await queryRead(commentId);
      }
      if (isClosed ||
          version != _contentVersion ||
          !identical(account, Accounts.main)) {
        return;
      }
      isLoaded.value = loaded;
      if (loaded) {
        super.onRefresh();
        if (heartbeat.isLogin &&
            identical(heartbeat, Accounts.heartbeat) &&
            !Pref.historyPause) {
          VideoHttp.historyReport(account: heartbeat, aid: commentId, type: 5);
        }
      }
    } finally {
      if (version == _contentVersion) _contentLoading = false;
    }
  }

  Future<void> onFav() async {
    if (isClosed || _favoriteOperation != null) return;
    final context = _context;
    if (!context.account.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final favorite = stats.value?.favorite;
    if (favorite == null) return;
    final articleId = commentId;
    final isFav = favorite.status ?? false;
    final operation = _favoriteOperation = Object();
    try {
      final res = type == 'read'
          ? isFav
                ? await FavHttp.delFavArticle(
                    account: context.account,
                    id: articleId,
                  )
                : await FavHttp.addFavArticle(
                    account: context.account,
                    id: articleId,
                  )
          : await FavHttp.communityAction(
              account: context.account,
              opusId: id,
              action: isFav ? 4 : 3,
            );
      if (!_owns(context) ||
          articleId != commentId ||
          !identical(favorite, stats.value?.favorite)) {
        return;
      }
      if (res.isSuccess) {
        _infoVersion++;
        favorite.status = !isFav;
        if (favorite.count case final count?) {
          favorite.count = max(0, count + (isFav ? -1 : 1));
        }
        stats.refresh();
        SmartDialog.showToast('${isFav ? '取消' : ''}收藏成功');
      } else {
        res.toast();
      }
    } finally {
      if (identical(_favoriteOperation, operation)) _favoriteOperation = null;
    }
  }

  Future<void> onLike() async {
    if (isClosed || _likeOperation != null) return;
    final context = _context;
    if (!context.account.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final like = stats.value?.like;
    if (like == null) return;
    final dynamicId = (opusData?.idStr ?? articleData?.dynIdStr)?.toString();
    if ((int.tryParse(dynamicId ?? '') ?? 0) <= 0) {
      SmartDialog.showToast('暂未获取到文章动态编号，请刷新后重试');
      return;
    }
    final isLike = like.status ?? false;
    final operation = _likeOperation = Object();
    try {
      final res = await DynamicsHttp.thumbDynamic(
        account: context.account,
        dynamicId: dynamicId,
        up: isLike ? 2 : 1,
      );
      if (!_owns(context) || !identical(like, stats.value?.like)) return;
      if (res.isSuccess) {
        _infoVersion++;
        like.status = !isLike;
        if (like.count case final count?) {
          like.count = max(0, count + (isLike ? -1 : 1));
        }
        stats.refresh();
        SmartDialog.showToast(!isLike ? '点赞成功' : '取消赞');
      } else {
        res.toast();
      }
    } finally {
      if (identical(_likeOperation, operation)) _likeOperation = null;
    }
  }

  @override
  Future<void> onReload() {
    if (!isLoaded.value) {
      loadingState.value = LoadingState.loading();
      return _queryContent();
    }
    return super.onReload();
  }

  @override
  void onClose() {
    _contentVersion++;
    _infoVersion++;
    super.onClose();
  }
}

class Summary {
  Avatar? author;
  String? title;
  String? cover;

  Summary({this.author, this.title, this.cover});
}

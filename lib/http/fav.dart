import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/api_response.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/fav_order_type.dart';
import 'package:pili_aurora/models/remote/fav/fav_article/data.dart';
import 'package:pili_aurora/models/remote/fav/fav_detail/data.dart';
import 'package:pili_aurora/models/remote/fav/fav_folder/data.dart';
import 'package:pili_aurora/models/remote/fav/fav_folder/list.dart';
import 'package:pili_aurora/models/remote/fav/fav_note/list.dart';
import 'package:pili_aurora/models/remote/fav/fav_pgc/data.dart';
import 'package:pili_aurora/models/remote/fav/fav_topic/data.dart';
import 'package:pili_aurora/models/remote/space/space_cheese/data.dart';
import 'package:pili_aurora/models/remote/space/space_fav/data.dart';
import 'package:pili_aurora/models/remote/sub/sub_detail/data.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/app_sign.dart';
import 'package:pili_aurora/utils/wbi_sign.dart';
import 'package:dio/dio.dart';

abstract final class FavHttp {
  static Future<LoadingState<bool>> subscriptionVideoAvailable(int aid) async {
    try {
      final result = await Request().requestApi<bool>(
        Api.videoIntro,
        kind: ApiCallKind.query,
        decode: (body) {
          if (body['data'] is! Map) throw const FormatException('视频状态响应不完整');
          return true;
        },
        queryParameters: await WbiSign.makSign({'aid': aid}),
      );
      // 只有明确不存在才能清理订阅，权限、风控和网络失败继续保留。
      return result is Error && result.code == -404
          ? const Success(false)
          : result;
    } catch (error, stackTrace) {
      return Error.fromException(error, stackTrace);
    }
  }

  static Future<LoadingState<void>> favFavFolder(
    Object mediaId, {
    Account? account,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.favFavFolder,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'media_id': mediaId,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<void>> unfavFavFolder(
    Object mediaId, {
    Account? account,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.unfavFavFolder,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'media_id': mediaId,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<FavDetailData>> userFavFolderDetail({
    Account? account,
    required int mediaId,
    required int pn,
    required int ps,
    String keyword = '',
    FavOrderType order = FavOrderType.mtime,
    int type = 0,
  }) async {
    return await Request().requestApi(
      Api.favResourceList,
      kind: ApiCallKind.query,
      decode: (body) => FavDetailData.fromJson(body['data']),
      options: Options(extra: {'account': account ?? Accounts.main}),
      queryParameters: {
        'media_id': mediaId,
        'pn': pn,
        'ps': ps,
        'keyword': keyword,
        'order': order.name,
        'type': type,
        'tid': 0,
        'platform': 'web',
      },
    );
  }

  // 取消订阅
  static Future<LoadingState<void>> cancelSub({
    required int id,
    required int type,
  }) async {
    return await Request().requestApi<void>(
      type == 11 ? Api.unfavFolder : Api.unfavSeason,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: type == 11
          ? {
              'media_id': id,
              'csrf': Accounts.main.csrf,
            }
          : {
              'platform': 'web',
              'season_id': id,
              'csrf': Accounts.main.csrf,
            },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  static Future<LoadingState<SubDetailData>> favSeasonList({
    required int id,
    required int pn,
    required int ps,
  }) async {
    return await Request().requestApi(
      Api.favSeasonList,
      kind: ApiCallKind.query,
      decode: (body) => SubDetailData.fromJson(body['data']),
      queryParameters: {
        'season_id': id,
        'ps': ps,
        'pn': pn,
      },
    );
  }

  static Future<LoadingState<SpaceCheeseData>> favPugv({
    required int mid,
    required int page,
  }) async {
    return await Request().requestApi(
      Api.favPugv,
      kind: ApiCallKind.query,
      decode: (body) => SpaceCheeseData.fromJson(body['data']),
      queryParameters: {
        'mid': mid,
        'ps': 20,
        'pn': page,
        'web_location': 333.1387,
      },
    );
  }

  static Future<LoadingState<void>> addFavPugv(Object seasonId) async {
    return await Request().requestApi<void>(
      Api.addFavPugv,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'season_id': seasonId,
        'csrf': Accounts.main.csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  static Future<LoadingState<void>> delFavPugv(Object seasonId) async {
    return await Request().requestApi<void>(
      Api.delFavPugv,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'season_id': seasonId,
        'csrf': Accounts.main.csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  static Future<LoadingState<FavTopicData>> favTopic({
    required int page,
  }) async {
    return await Request().requestApi(
      Api.favTopicList,
      kind: ApiCallKind.query,
      decode: (body) => FavTopicData.fromJson(body['data']),
      queryParameters: {
        'page_size': 24,
        'page_num': page,
        'web_location': 333.1387,
      },
    );
  }

  static Future<LoadingState<void>> addFavTopic(Object topicId) async {
    return await Request().requestApi<void>(
      Api.addFavTopic,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'topic_id': topicId,
        'csrf': Accounts.main.csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  static Future<LoadingState<void>> delFavTopic(Object topicId) async {
    return await Request().requestApi<void>(
      Api.delFavTopic,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'topic_id': topicId,
        'csrf': Accounts.main.csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  static Future<LoadingState<void>> likeTopic(
    Object topicId,
    bool isLike,
  ) async {
    return await Request().requestApi<void>(
      Api.likeTopic,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'action': isLike ? 'cancel_like' : 'like',
        'up_mid': Accounts.main.mid,
        'topic_id': topicId,
        'csrf': Accounts.main.csrf,
        'business': 'topic',
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  static Future<LoadingState<FavArticleData>> favArticle({
    Account? account,
    required int page,
  }) async {
    return await Request().requestApi(
      Api.favArticle,
      kind: ApiCallKind.query,
      decode: (body) => FavArticleData.fromJson(body['data']),
      options: Options(extra: {'account': account ?? Accounts.main}),
      queryParameters: {
        'page_size': 20,
        'page': page,
      },
    );
  }

  static Future<LoadingState<void>> addFavArticle({
    Account? account,
    required Object id,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.addFavArticle,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'id': id,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<void>> delFavArticle({
    Account? account,
    required Object id,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.delFavArticle,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'id': id,
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<List<FavNoteItemModel>?>> userNoteList({
    required int page,
  }) async {
    return await Request().requestApi(
      Api.userNoteList,
      kind: ApiCallKind.query,
      decode: (body) => (body['data']?['list'] as List?)
          ?.map((item) => FavNoteItemModel.fromJson(item))
          .toList(),
      queryParameters: {
        'pn': page,
        'ps': 10,
        'csrf': Accounts.main.csrf,
      },
    );
  }

  static Future<LoadingState<List<FavNoteItemModel>?>> noteList({
    required int page,
  }) async {
    return await Request().requestApi(
      Api.noteList,
      kind: ApiCallKind.query,
      decode: (body) => (body['data']?['list'] as List?)
          ?.map((item) => FavNoteItemModel.fromJson(item))
          .toList(),
      queryParameters: {
        'pn': page,
        'ps': 10,
        'csrf': Accounts.main.csrf,
      },
    );
  }

  static Future<LoadingState<void>> delNote({
    required bool isPublish,
    required String noteIds,
  }) async {
    return await Request().requestApi<void>(
      isPublish ? Api.delPublishNote : Api.delNote,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        isPublish ? 'cvids' : 'note_ids': noteIds,
        'csrf': Accounts.main.csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<FavPgcData>> favPgc({
    required int type,
    required int pn,
    int? followStatus,
    Object? mid,
    Account? account,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi(
      Api.favPgc,
      kind: ApiCallKind.query,
      decode: (body) => FavPgcData.fromJson(body['data']),
      options: Options(extra: {'account': account}),
      queryParameters: {
        'vmid': mid ?? account.mid,
        'type': type,
        'follow_status': ?followStatus,
        'pn': pn,
      },
    );
  }

  // 收藏夹
  static Future<LoadingState<FavFolderData>> userfavFolder({
    Account? account,
    required int pn,
    required int ps,
    required dynamic mid,
  }) async {
    return await Request().requestApi(
      Api.userFavFolder,
      kind: ApiCallKind.query,
      decode: (body) => FavFolderData.fromJson(body['data']),
      options: Options(extra: {'account': account ?? Accounts.main}),
      queryParameters: {
        'pn': pn,
        'ps': ps,
        'up_mid': mid,
      },
    );
  }

  static Future<LoadingState<void>> sortFavFolder({
    Account? account,
    required String sort,
  }) async {
    account ??= Accounts.main;
    Map<String, dynamic> data = {
      'sort': sort,
      'csrf': account.csrf,
    };
    AppSign.appSign(data);
    return await Request().requestApi<void>(
      Api.sortFavFolder,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: data,
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<void>> sortFav({
    Account? account,
    required Object mediaId,
    required String sort,
  }) async {
    account ??= Accounts.main;
    Map<String, dynamic> data = {
      'media_id': mediaId,
      'sort': sort,
      'csrf': account.csrf,
    };
    AppSign.appSign(data);
    return await Request().requestApi<void>(
      Api.sortFav,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: data,
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<void>> cleanFav({
    Account? account,
    required Object mediaId,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.cleanFav,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'media_id': mediaId,
        'platform': 'web',
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<void>> deleteFolder({
    Account? account,
    required String mediaIds,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.deleteFolder,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'media_ids': mediaIds,
        'platform': 'web',
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<FavFolderInfo>> addOrEditFolder({
    Account? account,
    required bool isAdd,
    dynamic mediaId,
    required String title,
    required int privacy,
    required String cover,
    required String intro,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi(
      isAdd ? Api.addFolder : Api.editFolder,
      kind: ApiCallKind.mutation,
      decode: _decodeFolder,
      data: {
        'title': title,
        'intro': intro,
        'privacy': privacy,
        'cover': cover.isNotEmpty ? Uri.encodeFull(cover) : cover,
        'csrf': account.csrf,
        'media_id': ?mediaId,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<FavFolderInfo>> favFolderInfo({
    Account? account,
    required Object mediaId,
  }) async {
    return await Request().requestApi(
      Api.favFolderInfo,
      kind: ApiCallKind.query,
      decode: _decodeFolder,
      options: Options(extra: {'account': account ?? Accounts.main}),
      queryParameters: {
        'media_id': mediaId,
      },
    );
  }

  static Future<LoadingState<void>> seasonFav({
    required bool isFav,
    required dynamic seasonId,
  }) async {
    return await Request().requestApi<void>(
      isFav ? Api.unfavSeason : Api.favSeason,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'platform': 'web',
        'season_id': seasonId,
        'csrf': Accounts.main.csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<List<SpaceFavData>?>> spaceFav({
    required int mid,
  }) async {
    final params = {
      'build': 8430300,
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'channel': 'master',
      'mobi_app': 'android',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statisticsApp,
      'up_mid': mid,
    };
    return await Request().requestApi(
      Api.spaceFav,
      kind: ApiCallKind.query,
      decode: (body) => (body['data'] as List?)
          ?.map((e) => SpaceFavData.fromJson(e))
          .toList(),
      queryParameters: params,
      options: Options(
        headers: {
          'bili-http-engine': 'cronet',
          'user-agent': Constants.userAgentApp,
        },
      ),
    );
  }

  static Future<LoadingState<void>> communityAction({
    Account? account,
    required Object opusId,
    required Object action,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.communityAction,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      queryParameters: {
        'csrf': account.csrf,
      },
      data: {
        "entity": {
          "object_id_str": opusId,
          "type": {"biz": 2},
        },
        "action": action, // 3 fav, 4 unfav
      },
      options: Options(extra: {'account': account}),
    );
  }

  // （取消）收藏
  static Future<LoadingState<void>> favVideo({
    Account? account,
    required String resources,
    String? addIds,
    String? delIds,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.favVideo,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'resources': resources,
        'add_media_ids': addIds ?? '',
        'del_media_ids': delIds ?? '',
        'csrf': account.csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
  }

  // （取消）收藏
  static Future<LoadingState<void>> unfavAll({
    Account? account,
    required Object rid,
    required Object type,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      Api.unfavAll,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'rid': rid,
        'type': type,
        'csrf': account.csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        extra: {'account': account},
      ),
    );
  }

  static Future<LoadingState<void>> copyOrMoveFav({
    Account? account,
    required bool isCopy,
    required bool isFav,
    required dynamic srcMediaId,
    required dynamic tarMediaId,
    dynamic mid,
    required String resources,
  }) async {
    account ??= Accounts.main;
    return await Request().requestApi<void>(
      isFav
          ? isCopy
                ? Api.copyFav
                : Api.moveFav
          : isCopy
          ? Api.copyToview
          : Api.moveToview,
      kind: ApiCallKind.mutation,
      decode: (_) {},
      data: {
        'src_media_id': ?srcMediaId,
        'tar_media_id': tarMediaId,
        'mid': ?mid,
        'resources': resources,
        'platform': 'web',
        'csrf': account.csrf,
      },
      options: Options(
        extra: {'account': account},
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
  }

  static Future<LoadingState<FavFolderData>> allFavFolders(
    Object mid, {
    Account? account,
  }) async {
    return await Request().requestApi(
      Api.favFolder,
      kind: ApiCallKind.query,
      decode: (body) => FavFolderData.fromJson(body['data']),
      options: Options(extra: {'account': account ?? Accounts.main}),
      queryParameters: {'up_mid': mid},
    );
  }

  // 查看视频被收藏在哪个文件夹
  static Future<LoadingState<FavFolderData>> videoInFolder({
    Account? account,
    dynamic mid,
    dynamic rid,
    dynamic type,
  }) async {
    return await Request().requestApi(
      Api.favFolder,
      kind: ApiCallKind.query,
      decode: (body) => FavFolderData.fromJson(body['data']),
      options: Options(extra: {'account': account ?? Accounts.main}),
      queryParameters: {
        'up_mid': mid,
        'rid': rid,
        'type': ?type,
      },
    );
  }

  static FavFolderInfo _decodeFolder(Map<String, dynamic> body) {
    final data = body['data'];
    if (data is! Map<String, dynamic> ||
        data['title'] is! String ||
        data['attr'] is! int) {
      throw const FormatException('收藏夹信息缺少名称或属性');
    }
    final folder = FavFolderInfo.fromJson(data);
    if (folder.id <= 0) throw const FormatException('收藏夹响应缺少有效 ID');
    return folder;
  }
}

import 'package:pili_aurora/utils/accounts/account.dart';

import 'dart:convert';

import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/msg/im_user_infos/datum.dart';
import 'package:pili_aurora/models/remote/msg/msg_at/data.dart';
import 'package:pili_aurora/models/remote/msg/msg_dnd/uid_setting.dart';
import 'package:pili_aurora/models/remote/msg/msg_like/data.dart';
import 'package:pili_aurora/models/remote/msg/msg_like_detail/data.dart';
import 'package:pili_aurora/models/remote/msg/msg_reply/data.dart';
import 'package:pili_aurora/models/remote/msg/msg_sys/data.dart';
import 'package:pili_aurora/models/remote/msg/session_ss/data.dart';
import 'package:pili_aurora/models/remote/single_unread/data.dart';
import 'package:pili_aurora/models/remote/upload_bfs/data.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/wbi_sign.dart';
import 'package:dio/dio.dart';

abstract final class MsgHttp {
  static Future<LoadingState<MsgReplyData>> msgFeedReplyMe({
    required Account account,
    int? cursor,
    int? cursorTime,
  }) async {
    final res = await _MessageRequest(account).get(
      Api.msgFeedReply,
      queryParameters: {
        'id': ?cursor,
        'reply_time': ?cursorTime,
        'platform': 'web',
        'mobi_app': 'web',
        'build': 0,
        'web_location': 333.40164,
      },
    );
    if (res.data['code'] == 0) {
      return Success(MsgReplyData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<MsgAtData>> msgFeedAtMe({
    required Account account,
    int? cursor,
    int? cursorTime,
  }) async {
    final res = await _MessageRequest(account).get(
      Api.msgFeedAt,
      queryParameters: {
        'id': ?cursor,
        'at_time': ?cursorTime,
        'platform': 'web',
        'mobi_app': 'web',
        'build': 0,
        'web_location': 333.40164,
      },
    );
    if (res.data['code'] == 0) {
      return Success(MsgAtData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<MsgLikeData>> msgFeedLikeMe({
    required Account account,
    int? cursor,
    int? cursorTime,
  }) async {
    final res = await _MessageRequest(account).get(
      Api.msgFeedLike,
      queryParameters: {
        'id': ?cursor,
        'like_time': ?cursorTime,
        'platform': 'web',
        'mobi_app': 'web',
        'build': 0,
        'web_location': 333.40164,
      },
    );
    if (res.data['code'] == 0) {
      return Success(MsgLikeData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<MsgLikeDetailData>> msgLikeDetail({
    required Account account,
    required Object cardId,
    required int pn,
    Object lastMid = 0,
  }) async {
    final res = await _MessageRequest(account).get(
      Api.msgLikeDetail,
      queryParameters: {
        'card_id': cardId,
        'pn': pn,
        'last_mid': lastMid,
        'platform': 'web',
        'build': 0,
        'mobi_app': 'web',
        'web_location': 333.40164,
      },
    );
    if (res.data['code'] == 0) {
      return Success(MsgLikeDetailData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<List<MsgSysItem>?>> msgFeedNotify({
    required Account account,
    int? cursor,
    int pageSize = 20,
  }) async {
    final res = await _MessageRequest(account).get(
      Api.msgSysNotify,
      queryParameters: {
        'cursor': ?cursor,
        'page_size': pageSize,
        'mobi_app': 'web',
        'build': 0,
        'web_location': 333.40164,
      },
    );
    if (res.data['code'] == 0) {
      return Success(
        (res.data['data'] as List?)
            ?.map((e) => MsgSysItem.fromJson(e))
            .toList(),
      );
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> msgSysUpdateCursor(
    int cursor, {
    required Account account,
  }) async {
    String csrf = account.csrf;
    final res = await _MessageRequest(account).get(
      Api.msgSysUpdateCursor,
      queryParameters: {
        'csrf': csrf,
        'cursor': cursor,
      },
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<Map>> uploadImage({
    Account? account,
    required dynamic path,
    required String bucket,
    required String dir,
  }) async {
    final requestAccount = account ?? Accounts.main;
    final res = await _MessageRequest(account).post(
      Api.uploadImage,
      data: FormData.fromMap({
        'bucket': bucket,
        'file': await MultipartFile.fromFile(path),
        'dir': dir,
        'csrf': requestAccount.csrf,
      }),
    );
    if (res.data['code'] == 0) {
      return Success(res.data['data']);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<UploadBfsResData>> uploadBfs({
    Account? account,
    required String path,
    String? category,
    String? biz,
    CancelToken? cancelToken,
  }) async {
    final requestAccount = account ?? Accounts.main;
    final res = await _MessageRequest(account).post(
      Api.uploadBfs,
      data: FormData.fromMap({
        'file_up': await MultipartFile.fromFile(path),
        'category': ?category,
        'biz': ?biz,
        'csrf': requestAccount.csrf,
      }),
      cancelToken: cancelToken,
    );
    if (res.data['code'] == 0) {
      return Success(UploadBfsResData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> removeDynamic({
    Account? account,
    required Object dynIdStr,
    Object? dynType,
    Object? ridStr,
  }) async {
    final requestAccount = account ?? Accounts.main;
    final res = await _MessageRequest(account).post(
      Api.removeDynamic,
      queryParameters: {
        'platform': 'web',
        'csrf': requestAccount.csrf,
      },
      data: {
        "dyn_id_str": dynIdStr,
        "dyn_type": ?dynType,
        "rid_str": ?ridStr,
      },
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> removeMsg(
    Object talkerId, {
    required Account account,
  }) async {
    String csrf = account.csrf;
    Map<String, dynamic> data = await WbiSign.makSign({
      'talker_id': talkerId,
      'session_type': 1,
      'build': 0,
      'mobi_app': 'web',
      'csrf_token': csrf,
      'csrf': csrf,
    });
    final res = await _MessageRequest(account).post(
      HttpString.tUrl + Api.removeMsg,
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> delMsgfeed(
    int tp,
    dynamic id, {
    required Account account,
  }) async {
    String csrf = account.csrf;
    final res = await _MessageRequest(account).post(
      Api.delMsgfeed,
      data: {
        'tp': tp,
        'id': id,
        'build': 0,
        'mobi_app': 'web',
        'csrf_token': csrf,
        'csrf': csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> delSysMsg(
    Object id, {
    required Account account,
  }) async {
    String csrf = account.csrf;
    final res = await _MessageRequest(account).post(
      HttpString.messageBaseUrl + Api.delSysMsg,
      queryParameters: {
        'mobi_app': 'android',
        'csrf': csrf,
      },
      data: {
        'csrf': csrf,
        'ids': [id],
        'station_ids': [],
        'type': 4,
        'mobi_app': 'android',
      },
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  // 消息标记已读
  static Future<LoadingState<void>> ackSessionMsg({
    required Account account,
    required int talkerId,
    required int ackSeqno,
  }) async {
    String csrf = account.csrf;
    final params = await WbiSign.makSign({
      'talker_id': talkerId,
      'session_type': 1,
      'ack_seqno': ackSeqno,
      'build': 0,
      'mobi_app': 'web',
      'csrf_token': csrf,
      'csrf': csrf,
    });
    final res = await _MessageRequest(account)
        .get(Api.ackSessionMsg, queryParameters: params);
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(
        "message: ${res.data['message']},"
        " msg: ${res.data['msg']},"
        " code: ${res.data['code']}",
      );
    }
  }

  static Future<LoadingState<void>> msgSetNotice({
    required Account account,
    required Object id,
    required int noticeState,
  }) async {
    final csrf = account.csrf;
    final res = await _MessageRequest(account).post(
      Api.msgSetNotice,
      data: {
        'mobi_app': 'web',
        'platform': 'web',
        'tp': 0,
        'id': id,
        'notice_state': noticeState,
        'build': 0,
        'csrf_token': csrf,
        'csrf': csrf,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
      ),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> setMsgDnd({
    required Account account,
    required Object uid,
    required int setting,
    required dndUid,
  }) async {
    final csrf = account.csrf;
    final res = await _MessageRequest(account).post(
      Api.setMsgDnd,
      data: {
        'uid': uid,
        'setting': setting,
        'dnd_uid': dndUid,
        'build': 0,
        'mobi_app': 'web',
        'csrf_token': csrf,
        'csrf': csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> setPushSs({
    required Account account,
    required int setting,
    required talkerUid,
  }) async {
    final csrf = account.csrf;
    final res = await _MessageRequest(account).post(
      Api.setPushSs,
      data: {
        'setting': setting,
        'talker_uid': talkerUid,
        'build': 0,
        'mobi_app': 'web',
        'csrf_token': csrf,
        'csrf': csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<List<ImUserInfosData>?>> imUserInfos({
    required Account account,
    required String uids,
  }) async {
    final csrf = account.csrf;
    final res = await _MessageRequest(account).get(
      Api.imUserInfos,
      queryParameters: {
        'uids': uids,
        'build': 0,
        'mobi_app': 'web',
        'csrf_token': csrf,
        'csrf': csrf,
      },
    );
    if (res.data['code'] == 0) {
      return Success(
        (res.data['data'] as List?)
            ?.map((e) => ImUserInfosData.fromJson(e))
            .toList(),
      );
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<SessionSsData>> getSessionSs({
    required Account account,
    required Object talkerUid,
  }) async {
    final csrf = account.csrf;
    final res = await _MessageRequest(account).get(
      Api.getSessionSs,
      queryParameters: {
        'talker_uid': talkerUid,
        'build': 0,
        'mobi_app': 'web',
        'csrf_token': csrf,
        'csrf': csrf,
      },
    );
    if (res.data['code'] == 0) {
      return Success(SessionSsData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<List<UidSetting>?>> getMsgDnd({
    required Account account,
    required Object uidsStr,
  }) async {
    final csrf = account.csrf;
    final res = await _MessageRequest(account).get(
      Api.getMsgDnd,
      queryParameters: {
        'own_uid': account.mid,
        'uids_str': uidsStr,
        'build': 0,
        'mobi_app': 'web',
        'csrf_token': csrf,
        'csrf': csrf,
      },
    );
    if (res.data['code'] == 0) {
      return Success(
        (res.data['data']?['uid_settings'] as List?)
            ?.map((e) => UidSetting.fromJson(e))
            .toList(),
      );
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<SingleUnreadData>> msgUnread({
    required Account account,
  }) async {
    final res = await _MessageRequest(account).get(
      Api.msgUnread,
      queryParameters: {
        'build': 0,
        'mobi_app': 'web',
        'unread_type': 0,
        'web_location': 333.1365,
      },
    );
    if (res.data['code'] == 0) {
      return Success(SingleUnreadData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }

  static Future<LoadingState<void>> imMsgReport({
    required Account account,
    required int accusedUid,
    required int reasonType,
    required String reasonDesc,
    required Map comment,
    required Map extra,
  }) async {
    final res = await _MessageRequest(account).post(
      Api.imMsgReport,
      data: {
        'biz_code': 4,
        'accused_uid': accusedUid,
        'object_id': accusedUid,
        'reason_type': reasonType,
        'reason_desc': reasonDesc,
        'module': 604,
        'comment': jsonEncode(comment),
        'extra': jsonEncode(extra),
        'csrf': account.csrf,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    if (res.data['code'] == 0) {
      return const Success(null);
    } else {
      return Error(res.data['message']);
    }
  }
}

// 显式账号请求保留网络异常，交由账号 Session 判定操作结果。
class _MessageRequest {
  const _MessageRequest(this.account);
  final Account? account;
  Options _options(Options? options) => (options ?? Options()).copyWith(
    extra: {...?options?.extra, 'account': account, 'noRetry': true},
  );
  Future<Response<dynamic>> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) => account == null
      ? Request().get(
          url,
          queryParameters: queryParameters,
          options: options,
          cancelToken: cancelToken,
        )
      : Request.dio.get(
          url,
          queryParameters: queryParameters,
          options: _options(options),
          cancelToken: cancelToken,
        );
  Future<Response<dynamic>> post(
    String url, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) => account == null
      ? Request().post(
          url,
          data: data,
          queryParameters: queryParameters,
          options: options,
          cancelToken: cancelToken,
        )
      : Request.dio.post(
          url,
          data: data,
          queryParameters: queryParameters,
          options: _options(options),
          cancelToken: cancelToken,
        );
}

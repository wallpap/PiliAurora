import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/grpc/bilibili/app/im/v1.pb.dart' hide SessionInfo;
import 'package:pili_aurora/grpc/bilibili/im/interfaces/v1.pb.dart';
import 'package:pili_aurora/grpc/bilibili/im/type.pb.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/grpc/url.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/random_id.dart';
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart' show PbMap;

abstract final class ImGrpc {
  static Future<LoadingState<RspSendMsg>> sendMsg({
    required Account account,
    required int senderUid,
    required int receiverId,
    required String content,
    MsgType msgType = MsgType.EN_MSG_TYPE_TEXT,
  }) {
    return GrpcReq.request(
      GrpcUrl.sendMsg,
      ReqSendMsg(
        msg: Msg(
          senderUid: Int64(senderUid),
          receiverType: 1,
          receiverId: Int64(receiverId),
          msgType: msgType.value,
          content: content,
          timestamp: Int64(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          msgStatus: 0,
          newFaceVersion: 1,
        ),
        devId: newUuidV4(),
      ),
      RspSendMsg.fromBuffer,
      kind: .mutation,
      account: account,
    );
  }

  static Future<LoadingState<RspShareList>> shareList({
    required Account account,
    int size = 10,
  }) {
    return GrpcReq.request(
      GrpcUrl.shareList,
      ReqShareList(size: size),
      RspShareList.fromBuffer,
      kind: .query,
      account: account,
    );
  }

  static Future<LoadingState<RspSessionMsg>> syncFetchSessionMsgs({
    required Account account,
    required int talkerId,
    Int64? endSeqno,
    Int64? beginSeqno,
  }) {
    return GrpcReq.request(
      GrpcUrl.syncFetchSessionMsgs,
      ReqSessionMsg(
        talkerId: Int64(talkerId),
        sessionType: 1,
        endSeqno: endSeqno,
        beginSeqno: beginSeqno,
        size: 20,
        devId: '1',
      ),
      RspSessionMsg.fromBuffer,
      kind: .query,
      account: account,
    );
  }

  static Future<LoadingState<SessionMainReply>> sessionMain({
    required Account account,
    PbMap<int, Offset>? offset,
  }) {
    return GrpcReq.request(
      GrpcUrl.sessionMain,
      SessionMainReq(
        paginationParams: PaginationParams(offsets: offset?.entries),
      ),
      SessionMainReply.fromBuffer,
      kind: .query,
      account: account,
    );
  }

  static Future<LoadingState<SessionSecondaryReply>> sessionSecondary({
    required Account account,
    PbMap<int, Offset>? offset,
    SessionPageType? pageType,
  }) {
    return GrpcReq.request(
      GrpcUrl.sessionSecondary,
      SessionSecondaryReq(
        paginationParams: PaginationParams(offsets: offset?.entries),
        pageType: pageType,
      ),
      SessionSecondaryReply.fromBuffer,
      kind: .query,
      account: account,
    );
  }

  static Future<LoadingState<ClearUnreadReply>> clearUnread({
    required Account account,
    SessionPageType? pageType,
    SessionId? sessionId,
  }) {
    return GrpcReq.request(
      GrpcUrl.clearUnread,
      ClearUnreadReq(
        pageType: pageType,
        sessionId: sessionId,
      ),
      ClearUnreadReply.fromBuffer,
      kind: .mutation,
      account: account,
    );
  }

  static Future<LoadingState<SessionUpdateReply>> sessionUpdate({
    required Account account,
    SessionPageType? pageType,
    SessionId? sessionId,
  }) {
    return GrpcReq.request(
      GrpcUrl.sessionUpdate,
      SessionUpdateReq(
        pageType: pageType,
        sessionId: sessionId,
      ),
      SessionUpdateReply.fromBuffer,
      kind: .mutation,
      account: account,
    );
  }

  static Future<LoadingState<PinSessionReply>> pinSession({
    required Account account,
    SessionId? sessionId,
    Int64? topTimeMicros,
  }) {
    return GrpcReq.request(
      GrpcUrl.pinSession,
      PinSessionReq(
        sessionId: sessionId,
        topTimeMicros: topTimeMicros,
      ),
      PinSessionReply.fromBuffer,
      kind: .mutation,
      account: account,
    );
  }

  static Future<LoadingState<UnPinSessionReply>> unpinSession({
    required Account account,
    SessionId? sessionId,
  }) {
    return GrpcReq.request(
      GrpcUrl.unpinSession,
      UnPinSessionReq(
        sessionId: sessionId,
      ),
      UnPinSessionReply.fromBuffer,
      kind: .mutation,
      account: account,
    );
  }

  static Future<LoadingState<DeleteSessionListReply>> deleteSessionList({
    required Account account,
    SessionPageType? pageType,
  }) {
    return GrpcReq.request(
      GrpcUrl.deleteSessionList,
      DeleteSessionListReq(
        pageType: pageType,
      ),
      DeleteSessionListReply.fromBuffer,
      kind: .mutation,
      account: account,
    );
  }

  static Future<LoadingState<GetImSettingsReply>> getImSettings({
    required Account account,
    IMSettingType? type,
  }) {
    return GrpcReq.request(
      GrpcUrl.getImSettings,
      GetImSettingsReq(
        type: type,
      ),
      GetImSettingsReply.fromBuffer,
      kind: .query,
      account: account,
    );
  }

  static Future<LoadingState<SetImSettingsReply>> setImSettings({
    required Account account,
    Map<int, Setting>? settings,
  }) {
    return GrpcReq.request(
      GrpcUrl.setImSettings,
      SetImSettingsReq(settings: settings?.entries),
      SetImSettingsReply.fromBuffer,
      kind: .mutation,
      account: account,
    );
  }

  static Future<LoadingState<KeywordBlockingListReply>> keywordBlockingList({
    required Account account,
  }) {
    return GrpcReq.request(
      GrpcUrl.keywordBlockingList,
      KeywordBlockingListReq(),
      KeywordBlockingListReply.fromBuffer,
      kind: .query,
      account: account,
    );
  }

  static Future<LoadingState<KeywordBlockingAddReply>> keywordBlockingAdd(
    String keyword, {
    required Account account,
  }) {
    return GrpcReq.request(
      GrpcUrl.keywordBlockingAdd,
      KeywordBlockingAddReq(keyword: keyword),
      KeywordBlockingAddReply.fromBuffer,
      kind: .mutation,
      account: account,
    );
  }

  static Future<LoadingState<KeywordBlockingDeleteReply>> keywordBlockingDelete(
    String keyword, {
    required Account account,
  }) {
    return GrpcReq.request(
      GrpcUrl.keywordBlockingDelete,
      KeywordBlockingDeleteReq(keyword: keyword),
      KeywordBlockingDeleteReply.fromBuffer,
      kind: .mutation,
      account: account,
    );
  }

  static Future<LoadingState<RspTotalUnread>> getTotalUnread({
    required Account account,
    int? unreadType,
  }) {
    return GrpcReq.request(
      GrpcUrl.getTotalUnread,
      ReqTotalUnread(unreadType: unreadType, showUnfollowList: 1),
      RspTotalUnread.fromBuffer,
      kind: .query,
      account: account,
    );
  }

  static Future<LoadingState<SessionInfo>> sessionDetail({
    required Account account,
    Int64? talkerId,
    int? sessionType,
    Int64? uid,
  }) {
    return GrpcReq.request(
      GrpcUrl.sessionDetail,
      ReqSessionDetail(talkerId: talkerId, sessionType: sessionType, uid: uid),
      SessionInfo.fromBuffer,
      kind: .query,
      account: account,
    );
  }
}

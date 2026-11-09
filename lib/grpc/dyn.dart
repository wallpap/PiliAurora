import 'package:pili_aurora/grpc/bilibili/app/dynamic/v1.pb.dart'
    show DynRedReq, TabOffset, DynRedReply;
import 'package:pili_aurora/grpc/bilibili/app/dynamic/v2.pb.dart'
    show
        OpusType,
        OpusDetailReq,
        OpusDetailResp,
        LikeListReq,
        LikeListReply,
        RepostListReq,
        RepostListRsp,
        RepostType;
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/grpc/url.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:fixnum/fixnum.dart';

abstract final class DynGrpc {
  static Future<int?> dynRed() async {
    final res = await GrpcReq.request(
      GrpcUrl.dynRed,
      DynRedReq(tabOffset: [TabOffset(tab: 1)]),
      DynRedReply.fromBuffer,
      kind: .query,
    );
    return res.dataOrNull?.dynRedItem.count.toInt();
  }

  static Future<LoadingState<OpusDetailResp>> opusDetail({
    OpusType? opusType,
    required int oid,
  }) {
    return GrpcReq.request(
      GrpcUrl.opusDetail,
      OpusDetailReq(
        opusType: opusType,
        oid: Int64(oid),
      ),
      OpusDetailResp.fromBuffer,
      kind: .query,
    );
  }

  static Future<LoadingState<LikeListReply>> likeList({
    Account? account,
    required String dynamicId,
    Int64? dynType,
    Int64? rid,
    Int64? uidOffset,
    required int page,
  }) {
    return GrpcReq.request(
      GrpcUrl.likeList,
      LikeListReq(
        dynamicId: dynamicId,
        dynType: dynType,
        rid: rid,
        uidOffset: uidOffset,
        page: page,
      ),
      LikeListReply.fromBuffer,
      kind: .query,
      account: account ?? Accounts.main,
    );
  }

  static Future<LoadingState<RepostListRsp>> repostList({
    Account? account,
    required String dynamicId,
    Int64? dynType,
    Int64? rid,
    String? offset,
    String? from,
    RepostType repostType = .repost_general,
  }) {
    return GrpcReq.request(
      GrpcUrl.repostList,
      RepostListReq(
        dynamicId: dynamicId,
        dynType: dynType,
        rid: rid,
        offset: offset,
        repostType: repostType,
      ),
      RepostListRsp.fromBuffer,
      kind: .query,
      account: account ?? Accounts.main,
    );
  }
}

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/msg.dart';
import 'package:pili_aurora/models/remote/msg/msg_at/content.dart' as at_model;
import 'package:pili_aurora/models/remote/msg/msg_at/item.dart';
import 'package:pili_aurora/models/remote/msg/msg_at/user.dart' as at_model;
import 'package:pili_aurora/models/remote/msg/msg_like/content.dart'
    as like_model;
import 'package:pili_aurora/models/remote/msg/msg_like/data.dart';
import 'package:pili_aurora/models/remote/msg/msg_like/item.dart';
import 'package:pili_aurora/models/remote/msg/msg_like/user.dart' as like_model;
import 'package:pili_aurora/models/remote/msg/msg_like_detail/card.dart';
import 'package:pili_aurora/models/remote/msg/msg_like_detail/item.dart';
import 'package:pili_aurora/models/remote/msg/msg_like_detail/user.dart'
    as detail;
import 'package:pili_aurora/models/remote/msg/msg_reply/content.dart'
    as reply_model;
import 'package:pili_aurora/models/remote/msg/msg_reply/item.dart';
import 'package:pili_aurora/models/remote/msg/msg_reply/user.dart'
    as reply_model;
import 'package:pili_aurora/models/remote/msg/msg_sys/data.dart';
import 'package:pili_aurora/services/messaging/feed.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

abstract final class MessagingFeedAdapters {
  static Future<LoadingState<FeedPage<MsgReplyItem>>> reply(
    Account account,
    FeedCursor? cursor,
  ) async {
    final result = await MsgHttp.msgFeedReplyMe(
      cursor: cursor?.id,
      cursorTime: cursor?.time,
      account: account,
    );
    return _map(result, (data) {
      final items = data.items?.map(_copyReply).toList() ?? <MsgReplyItem>[];
      final next = data.cursor;
      return FeedPage(
        items: items,
        cursor: next == null ? null : FeedCursor(id: next.id, time: next.time),
        isEnd: next?.isEnd == true,
      );
    });
  }

  static Future<LoadingState<FeedPage<MsgAtItem>>> at(
    Account account,
    FeedCursor? cursor,
  ) async {
    final result = await MsgHttp.msgFeedAtMe(
      cursor: cursor?.id,
      cursorTime: cursor?.time,
      account: account,
    );
    return _map(result, (data) {
      final items = data.items?.map(_copyAt).toList() ?? <MsgAtItem>[];
      final next = data.cursor;
      return FeedPage(
        items: items,
        cursor: next == null ? null : FeedCursor(id: next.id, time: next.time),
        isEnd: next?.isEnd == true,
      );
    });
  }

  static Future<LoadingState<LikeFeedPage>> like(
    Account account,
    FeedCursor? cursor,
  ) async {
    final result = await MsgHttp.msgFeedLikeMe(
      cursor: cursor?.id,
      cursorTime: cursor?.time,
      account: account,
    );
    return _mapLike(result, (data) {
      final latest =
          data.latest?.items?.map(_copyLike).toList() ?? <MsgLikeItem>[];
      final totalData = data.total;
      final total =
          totalData?.items?.map(_copyLike).toList() ?? <MsgLikeItem>[];
      final next = totalData?.cursor;
      return LikeFeedPage(
        latest: latest,
        total: total,
        cursor: next == null ? null : FeedCursor(id: next.id, time: next.time),
        isEnd: next?.isEnd == true || total.isEmpty,
      );
    });
  }

  static Future<LoadingState<FeedPage<MsgLikeDetailItem>>> likeDetail(
    Account account,
    FeedCursor? cursor, {
    required String cardId,
  }) async {
    final page = cursor?.page ?? 1;
    final lastMid = cursor?.lastMid ?? 0;
    final result = await MsgHttp.msgLikeDetail(
      cardId: cardId,
      pn: page,
      lastMid: lastMid,
      account: account,
    );
    return _map(result, (data) {
      final items =
          data.items?.map(_copyLikeDetail).toList() ?? <MsgLikeDetailItem>[];
      final nextMid = items.isEmpty ? null : items.last.user?.mid;
      return FeedPage(
        items: items,
        cursor: FeedCursor(
          page: page + 1,
          lastMid: nextMid ?? lastMid,
        ),
        isEnd: data.page?.isEnd == true,
        metadata: data.card == null
            ? null
            : MsgLikeDetailCard(
                business: data.card!.business,
                title: data.card!.title,
              ),
      );
    });
  }

  static Future<LoadingState<FeedPage<MsgSysItem>>> system(
    Account account,
    FeedCursor? cursor,
  ) async {
    final result = await MsgHttp.msgFeedNotify(
      cursor: cursor?.id,
      account: account,
    );
    if (result case Success<List<MsgSysItem>?>(:final response)) {
      final source = response?.map(_copySystem).toList() ?? <MsgSysItem>[];
      final nextCursor = source.isEmpty ? null : source.last.cursor;
      return Success(
        FeedPage(
          items: source,
          cursor: nextCursor == null ? null : FeedCursor(id: nextCursor),
          isEnd: source.isEmpty,
          notifyUnread: cursor == null && source.firstOrNull?.cursor != null,
        ),
      );
    }
    return _map(result, (items) => FeedPage(items: items ?? const []));
  }

  static Future<LoadingState<void>> acknowledgeSystem(
    Account account,
    FeedPage<MsgSysItem> page,
  ) {
    final cursor = page.items.firstOrNull?.cursor;
    return cursor == null
        ? Future.value(const Error('消息缺少阅读位置'))
        : MsgHttp.msgSysUpdateCursor(cursor, account: account);
  }

  static Future<LoadingState<void>> deleteReply(Account account, Object id) =>
      MsgHttp.delMsgfeed(1, id, account: account);

  static Future<LoadingState<void>> deleteAt(Account account, Object id) =>
      MsgHttp.delMsgfeed(2, id, account: account);

  static Future<LoadingState<void>> deleteLike(Account account, Object id) =>
      MsgHttp.delMsgfeed(0, id, account: account);

  static Future<LoadingState<void>> deleteSystem(Account account, Object id) =>
      MsgHttp.delSysMsg(id, account: account);

  static Future<LoadingState<void>> setLikeNotice(
    Account account,
    Object id,
    int noticeState,
  ) => MsgHttp.msgSetNotice(
    id: id,
    noticeState: noticeState,
    account: account,
  );

  static MsgReplyItem _copyReply(MsgReplyItem item) => MsgReplyItem(
    id: item.id,
    user: item.user == null
        ? null
        : reply_model.User(
            mid: item.user!.mid,
            nickname: item.user!.nickname,
            avatar: item.user!.avatar,
          ),
    item: item.item == null
        ? null
        : reply_model.MsgReplyContent(
            subjectId: item.item!.subjectId,
            businessId: item.item!.businessId,
            business: item.item!.business,
            nativeUri: item.item!.nativeUri,
            rootReplyContent: item.item!.rootReplyContent,
            sourceContent: item.item!.sourceContent,
            targetReplyContent: item.item!.targetReplyContent,
          ),
    counts: item.counts,
    isMulti: item.isMulti,
    replyTime: item.replyTime,
  );

  static MsgAtItem _copyAt(MsgAtItem item) => MsgAtItem(
    id: item.id,
    user: item.user == null
        ? null
        : at_model.User(
            mid: item.user!.mid,
            nickname: item.user!.nickname,
            avatar: item.user!.avatar,
          ),
    item: item.item == null
        ? null
        : at_model.MsgAtContent(
            business: item.item!.business,
            image: item.item!.image,
            sourceContent: item.item!.sourceContent,
            nativeUri: item.item!.nativeUri,
          ),
    atTime: item.atTime,
  );

  static MsgLikeItem _copyLike(MsgLikeItem item) => MsgLikeItem(
    id: item.id,
    users: item.users
        ?.map(
          (user) => like_model.User(
            mid: user.mid,
            nickname: user.nickname,
            avatar: user.avatar,
          ),
        )
        .toList(),
    item: item.item == null
        ? null
        : like_model.MsgLikeContent(
            business: item.item!.business,
            title: item.item!.title,
            image: item.item!.image,
            nativeUri: item.item!.nativeUri,
          ),
    counts: item.counts,
    likeTime: item.likeTime,
    noticeState: item.noticeState,
  );

  static MsgLikeDetailItem _copyLikeDetail(MsgLikeDetailItem item) =>
      MsgLikeDetailItem(
        user: item.user == null
            ? null
            : detail.MsgLikeDetailUser(
                mid: item.user!.mid,
                nickname: item.user!.nickname,
                avatar: item.user!.avatar,
              ),
        likeTime: item.likeTime,
      );

  static MsgSysItem _copySystem(MsgSysItem item) => MsgSysItem(
    id: item.id,
    cursor: item.cursor,
    title: item.title,
    content: item.content,
    timeAt: item.timeAt,
  );

  static LoadingState<FeedPage<T>> _map<R, T>(
    LoadingState<R> state,
    FeedPage<T> Function(R response) convert,
  ) => switch (state) {
    Success<R>(:final response) => Success(convert(response)),
    Error() => state,
    Loading() => LoadingState<FeedPage<T>>.loading(),
  };

  static LoadingState<LikeFeedPage> _mapLike(
    LoadingState<MsgLikeData> state,
    LikeFeedPage Function(MsgLikeData response) convert,
  ) => switch (state) {
    Success<MsgLikeData>(:final response) => Success(convert(response)),
    Error() => state,
    Loading() => LoadingState<LikeFeedPage>.loading(),
  };
}

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/sub/sub/data.dart';
import 'package:pili_aurora/models/remote/sub/sub/list.dart';

typedef SubscriptionMedia = ({int id, int type, bool? valid});

class SubscriptionContentPage {
  const SubscriptionContentPage({
    required this.items,
    required this.hasMore,
    this.total,
  });

  final List<SubscriptionMedia> items;
  final bool hasMore;
  final int? total;
}

class SubscriptionCleanupResult {
  int removed = 0;
  int hidden = 0;
  int failed = 0;
}

class SubscriptionCleaner {
  const SubscriptionCleaner({
    required this.loadContents,
    required this.checkVideo,
    required this.cancel,
    required this.saveHidden,
  });

  final Future<LoadingState<SubscriptionContentPage>> Function(
    SubItemModel subscription,
    int page,
  )
  loadContents;
  final Future<LoadingState<bool>> Function(int aid) checkVideo;
  final Future<LoadingState<void>> Function(SubItemModel subscription) cancel;
  final Future<int> Function(SubItemModel subscription, Set<(int, int)> media)
  saveHidden;

  Future<SubscriptionCleanupResult> run(
    List<SubItemModel> subscriptions, {
    required bool hideInvalid,
    bool Function()? isCurrent,
    void Function(int processed, int total)? onProgress,
  }) async {
    final result = SubscriptionCleanupResult();
    final checkedVideos = <int, LoadingState<bool>>{};
    for (var index = 0; index < subscriptions.length; index++) {
      if (isCurrent?.call() == false) break;
      final subscription = subscriptions[index];
      onProgress?.call(index + 1, subscriptions.length);
      try {
        if (subscription.id == null ||
            !const [11, 21].contains(subscription.type)) {
          result.failed++;
          continue;
        }
        if (subscription.state == 1) {
          if ((await cancel(subscription)).isSuccess) {
            result.removed++;
          } else {
            result.failed++;
          }
          continue;
        }
        final invalid = <(int, int)>{};
        final seen = <(int, int)>{};
        var hasValid = false;
        var complete = true;
        var stopped = false;
        int? total;
        for (var page = 1; ; page++) {
          if (isCurrent?.call() == false) {
            stopped = true;
            break;
          }
          final response = await loadContents(subscription, page);
          if (response is! Success<SubscriptionContentPage>) {
            complete = false;
            break;
          }
          if (response.response.total case final count?) {
            if (total == null || count > total) total = count;
          }
          var added = 0;
          for (final media in response.response.items) {
            if (isCurrent?.call() == false) {
              stopped = true;
              break;
            }
            if (!seen.add((media.id, media.type))) continue;
            added++;
            if (media.id < 1) {
              complete = false;
              continue;
            }
            LoadingState<bool> validity = Success(media.valid ?? true);
            if (media.valid == null) {
              validity = checkedVideos[media.id] ??= await checkVideo(media.id);
            }
            switch (validity) {
              case Success(response: true):
                hasValid = true;
              case Success(response: false):
                invalid.add((media.id, media.type));
              case Error() || Loading():
                complete = false;
            }
            if (hasValid && !hideInvalid) break;
          }
          if (stopped ||
              !response.response.hasMore ||
              (hasValid && !hideInvalid)) {
            break;
          }
          if (added == 0) {
            complete = false;
            break;
          }
        }
        if (stopped || isCurrent?.call() == false) break;
        if (!hasValid && total != null && seen.length < total) complete = false;
        // 全部内容均已确认失效才取消订阅；空合集及请求失败保留。
        if (complete && !hasValid && invalid.isNotEmpty) {
          if ((await cancel(subscription)).isSuccess) {
            result.removed++;
          } else {
            result.failed++;
          }
        } else if (hasValid && hideInvalid && invalid.isNotEmpty) {
          result.hidden += await saveHidden(subscription, invalid);
        }
        if (!complete) result.failed++;
      } catch (_) {
        result.failed++;
      }
    }
    return result;
  }
}

/// 先读取完整订阅快照，再执行清理，避免取消订阅导致后续分页前移。
Future<LoadingState<List<SubItemModel>>> loadSubscriptionSnapshot(
  Future<LoadingState<SubData>> Function(int page) loadPage,
) async {
  final subscriptions = <SubItemModel>[];
  final seen = <(int?, int?)>{};
  for (var page = 1; ; page++) {
    final response = await loadPage(page);
    switch (response) {
      case Success(:final response):
        final items = response.list ?? const <SubItemModel>[];
        var added = 0;
        for (final item in items) {
          if (seen.add((item.type, item.id))) {
            subscriptions.add(item);
            added++;
          }
        }
        if (response.hasMore == false) return Success(subscriptions);
        if (response.hasMore == null) {
          return const Error('订阅分页信息不完整，请稍后重试');
        }
        if (added == 0) {
          return const Error('订阅分页未推进，请稍后重试');
        }
      case Error():
        return response;
      case Loading():
        return const Error('订阅列表尚未加载完成');
    }
  }
}

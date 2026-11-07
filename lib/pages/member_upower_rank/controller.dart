import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/models/remote/upower_rank/level_info.dart';
import 'package:pili_aurora/models/remote/upower_rank/rank_info.dart';
import 'package:pili_aurora/services/account_providers.dart';

typedef UpowerRankQuery = ({String mid, int? privilege, Object owner});

class UpowerRanking {
  UpowerRanking(Iterable<UpowerRankInfo> ranks, Iterable<LevelInfo> levels)
    : ranks = List.unmodifiable(ranks),
      levels = List.unmodifiable(levels);
  final List<UpowerRankInfo> ranks;
  final List<LevelInfo> levels;
}

final upowerRankingProvider = FutureProvider.autoDispose
    .family<UpowerRanking, UpowerRankQuery>((ref, query) async {
      final account = ref.watch(mainAccountProvider);
      final data = (await MemberHttp.upowerRank(
        account: account,
        upMid: query.mid,
        page: 1,
        privilegeType: query.privilege,
      )).data;
      return UpowerRanking(data.rankInfo ?? [], data.levelInfo ?? []);
    }, retry: (_, _) => null);

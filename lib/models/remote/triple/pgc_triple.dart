class PgcTriple {
  final int coin;
  final int coinNumber;
  final int favorite;
  int? fmid;
  int? follow;
  final int like;
  bool? relation;

  PgcTriple({
    required this.coin,
    required this.coinNumber,
    required this.favorite,
    this.fmid,
    this.follow,
    required this.like,
    this.relation,
  });

  factory PgcTriple.fromJson(Map<String, dynamic> json) {
    for (final field in ['coin', 'favorite', 'like']) {
      if (json[field] != 0 && json[field] != 1) {
        throw const FormatException('剧集三连回执缺少有效的互动状态');
      }
    }
    final count = json['coin_number'];
    if (count is! num ||
        !count.isFinite ||
        count < 0 ||
        count > 2 ||
        count != count.round()) {
      throw const FormatException('剧集三连回执缺少有效的投币数量');
    }
    return PgcTriple(
      coin: json["coin"],
      coinNumber: count.toInt(),
      favorite: json["favorite"],
      fmid: json["fmid"],
      follow: json["follow"],
      like: json["like"],
      relation: json["relation"],
    );
  }
}

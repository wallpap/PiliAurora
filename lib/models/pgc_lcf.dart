class PgcLCF {
  final int coinNumber;
  final int favorite;
  int? isOriginal;
  final int like;

  PgcLCF({
    required this.coinNumber,
    required this.favorite,
    this.isOriginal,
    required this.like,
  });

  factory PgcLCF.fromJson(Map<String, dynamic> json) {
    final count = json['coin_number'];
    if ((json['like'] != 0 && json['like'] != 1) ||
        (json['favorite'] != 0 && json['favorite'] != 1) ||
        count is! num ||
        !count.isFinite ||
        count < 0 ||
        count > 2 ||
        count != count.round()) {
      throw const FormatException('剧集互动状态不完整');
    }
    return PgcLCF(
      coinNumber: count.toInt(),
      favorite: json["favorite"],
      isOriginal: json["is_original"],
      like: json["like"],
    );
  }
}

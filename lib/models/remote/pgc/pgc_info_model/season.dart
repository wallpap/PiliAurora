class PgcSeason {
  int? seasonId;
  String? seasonTitle;
  String? cover;
  String? badge;

  PgcSeason({
    this.seasonId,
    this.seasonTitle,
    this.cover,
    this.badge,
  });

  factory PgcSeason.fromJson(Map<String, dynamic> json) {
    final rawSeasonId = json['season_id'];
    return PgcSeason(
      seasonId: rawSeasonId is int
          ? rawSeasonId
          : int.tryParse(rawSeasonId?.toString() ?? ''),
      seasonTitle: json['season_title'] as String? ?? json['title'] as String?,
      cover: json['cover'] as String?,
      badge: json['badge'] as String?,
    );
  }
}

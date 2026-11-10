class SeasonFollowStatus {
  const SeasonFollowStatus({required this.followed, this.status});

  final bool followed;
  final int? status;

  factory SeasonFollowStatus.fromJson(Map<String, dynamic> json) {
    final follow = json['follow'];
    if (follow != 0 && follow != 1) {
      throw const FormatException('追番状态缺少有效的关注标记');
    }
    return SeasonFollowStatus(
      followed: follow == 1,
      status: json['follow_status'] as int?,
    );
  }
}

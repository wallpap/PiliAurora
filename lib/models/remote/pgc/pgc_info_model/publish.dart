class Publish {
  String? pubTimeShow;
  String? releaseDateShow;
  String? timeLengthShow;

  Publish({
    this.pubTimeShow,
    this.releaseDateShow,
    this.timeLengthShow,
  });

  factory Publish.fromJson(Map<String, dynamic> json) => Publish(
    pubTimeShow:
        json['pub_time_show'] as String? ?? json['pub_date_show'] as String?,
    releaseDateShow: json['release_date_show'] as String?,
    timeLengthShow: json['time_length_show'] as String?,
  );
}

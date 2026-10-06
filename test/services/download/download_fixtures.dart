import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';

BiliDownloadEntryInfo downloadEntry({
  int aid = 1,
  int cid = 11,
  bool completed = false,
  int updatedAt = 0,
  bool episode = false,
}) => BiliDownloadEntryInfo(
  isCompleted: completed,
  totalBytes: 100,
  downloadedBytes: completed ? 100 : 10,
  title: '测试下载',
  cover: 'https://example.test/cover.jpg',
  preferedVideoQuality: 80,
  guessedTotalBytes: 100,
  totalTimeMilli: 60000,
  danmakuCount: 0,
  timeUpdateStamp: updatedAt,
  avid: aid,
  bvid: 'BV-test',
  typeTag: '80',
  seasonId: episode ? '22' : null,
  source: episode ? SourceInfo(avId: aid, cid: cid) : null,
  ep: episode
      ? EpInfo(
          avId: aid,
          page: 1,
          danmaku: 0,
          cover: '',
          episodeId: 33,
          index: '1',
          indexTitle: '第一集',
          from: 'bangumi',
          seasonType: 1,
          width: 1920,
          height: 1080,
          rotate: 0,
        )
      : null,
  pageData: episode
      ? null
      : PageInfo(cid: cid, page: 1, hasAlias: false, tid: 0),
);

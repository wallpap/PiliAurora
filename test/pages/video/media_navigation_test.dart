import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/episode.dart'
    as pgc;
import 'package:pili_aurora/models/remote/video/video_detail/episode.dart';
import 'package:pili_aurora/models/remote/video/video_detail/page.dart';
import 'package:pili_aurora/models/remote/video/video_detail/section.dart';
import 'package:pili_aurora/models/remote/video/video_detail/ugc_season.dart';
import 'package:pili_aurora/pages/common/common_intro_controller.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/video/introduction/local/controller.dart';
import 'package:pili_aurora/pages/video/introduction/pgc/controller.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/controller.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_repeat.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/services/audio_handler.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

class _Owner extends Fake implements PlaybackOwner {
  bool active = true;
  @override
  bool get isActive => active;
}

class _Player extends Fake implements PlPlayerController {
  @override
  PlayRepeat playRepeat = PlayRepeat.listOrder;
}

class _Video extends Fake implements VideoDetailController {
  @override
  final _Owner playbackOwner = _Owner();
  @override
  final plPlayerController = _Player();
  @override
  final cid = 1.obs;
  @override
  bool get isPlayAll => false;
}

class _Ugc extends UgcIntroController {
  _Ugc(this.video);
  final _Video video;
  @override
  VideoDetailController get videoDetailCtr => video;
  @override
  Future<bool> onChangeEpisode(
    BaseEpisodeItem episode, {
    bool isStein = false,
  }) async {
    cid.value = episode.cid!;
    video.cid.value = episode.cid!;
    return true;
  }
}

class _Pgc extends PgcIntroController {
  _Pgc(this.video);
  final _Video video;
  @override
  VideoDetailController get videoDetailCtr => video;
  @override
  Future<bool> onChangeEpisode(BaseEpisodeItem episode) async {
    video.cid.value = episode.cid!;
    return true;
  }
}

class _Local extends LocalIntroController {
  _Local(this.video);
  final _Video video;
  @override
  VideoDetailController get videoDetailCtr => video;
  @override
  void playIndex(int index, {BiliDownloadEntryInfo? entry}) {
    this.index.value = index;
  }
}

class _Entry extends Fake implements BiliDownloadEntryInfo {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
  });

  for (final mode in ['UGC 分P', 'UGC 合集', 'PGC', '本地列表']) {
    test('系统媒体上下曲复用 $mode 顺序，失活与切号后停止调度', () async {
      final video = _Video();
      final CommonIntroController controller;
      if (mode == '本地列表') {
        controller = _Local(video)..index.value = 0;
        (controller as _Local).list.addAll([_Entry(), _Entry(), _Entry()]);
      } else if (mode == 'PGC') {
        controller = _Pgc(video)
          ..setPlaybackEpisodes([
            for (var id = 1; id <= 3; id++) pgc.EpisodeItem(cid: id),
          ]);
      } else {
        final ugc = _Ugc(video)..cid = 1.obs;
        if (mode == 'UGC 分P') {
          ugc.videoDetail.value.pages = [
            for (var id = 1; id <= 3; id++) Part(cid: id),
          ];
        } else {
          ugc.videoDetail.value.ugcSeason = UgcSeason(
            sections: [
              SectionItem(
                episodes: [
                  for (var id = 1; id <= 3; id++) EpisodeItem(cid: id),
                ],
              ),
            ],
          );
        }
        controller = ugc;
      }
      int selected() =>
          controller is _Local ? controller.index.value + 1 : video.cid.value;
      final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
      videoPlayerServiceHandler = handler;
      final account = Accounts.main;
      addTearDown(() {
        Accounts.accountMode[AccountType.main.index] = account;
        handler.clear();
        videoPlayerServiceHandler = null;
        controller.onDelete();
      });
      handler.onVideoDetailChange(
        Part(part: mode),
        1,
        mode,
        navigation: controller.mediaNavigation,
      );
      await handler.skipToNext();
      expect(selected(), 2);
      await handler.skipToPrevious();
      expect(selected(), 1);
      video.playbackOwner.active = false;
      await handler.skipToNext();
      expect(selected(), 1);
      video.playbackOwner.active = true;
      Accounts.accountMode[AccountType.main.index] = LoginAccount(
        BiliCookieJar.fromJson({'DedeUserID': '999', 'bili_jct': 'fixture'}),
        null,
        null,
      );
      await handler.skipToNext();
      expect(selected(), 1);
    });
  }
}

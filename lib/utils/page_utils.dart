import 'dart:math';

import 'package:pili_aurora/common/widgets/fractionally_sized_box.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/common/widgets/image_viewer/gallery_viewer.dart';
import 'package:pili_aurora/common/widgets/image_viewer/hero_dialog_route.dart';
import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/image_preview_type.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/episode.dart';
import 'package:pili_aurora/models/remote/video/video_detail/dimension.dart';
import 'package:pili_aurora/pages/common/common_intro_controller.dart';
import 'package:pili_aurora/pages/common/publish/publish_route.dart';
import 'package:pili_aurora/pages/contact/view.dart';
import 'package:pili_aurora/pages/fav_panel/view.dart';
import 'package:pili_aurora/pages/share/view.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/services/messaging/sharing.dart';
import 'package:pili_aurora/utils/android/android_helper.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/app_scheme.dart';
import 'package:pili_aurora/utils/extension/context_ext.dart';
import 'package:pili_aurora/utils/extension/get_ext.dart';
import 'package:pili_aurora/utils/extension/size_ext.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';
import 'package:pili_aurora/utils/feed_back.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/navigation_request.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/url_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:collection/collection.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

abstract final class PageUtils {
  static RelativeRect menuPosition(Offset offset) {
    return .fromLTRB(offset.dx, offset.dy, offset.dx, 0);
  }

  static Future<void> imageView({
    int initialPage = 0,
    required List<SourceModel> imgList,
    int? quality,
    ValueChanged<int>? onPageChanged,
    String tag = '',
  }) {
    return Get.key.currentState!.push<void>(
      HeroDialogRoute(
        pageBuilder: (context, animation, secondaryAnimation) => GalleryViewer(
          sources: imgList,
          initIndex: initialPage,
          quality: quality ?? GlobalData().imgQuality,
          onPageChanged: onPageChanged,
          tag: tag,
        ),
      ),
    );
  }

  static Future<void> pmShare(
    BuildContext context, {
    required Map content,
  }) async {
    final route = ModalRoute.of(context);
    bool currentPage() => route?.isCurrent ?? true;
    final session = Messaging.instance.session;
    final sharing = sharingFor(session);
    if (!session.isActive) {
      SmartDialog.showToast('请先登录');
      return;
    }
    List<UserModel> userList = <UserModel>[];

    final res = await sharing.recentRecipients();
    if (!context.mounted || !currentPage() || !session.isActive) return;
    if (res case Success(:final response)) {
      if (response.isNotEmpty) {
        userList.addAll(
          response.map<UserModel>(
            (item) => UserModel(
              mid: item.id,
              name: item.name,
              avatar: item.avatar,
            ),
          ),
        );
      }
    }

    if (userList.isEmpty && context.mounted && currentPage()) {
      final UserModel? userModel = await Navigator.of(context).push(
        GetPageRoute(page: () => const ContactPage()),
      );
      if (userModel != null) {
        userList.add(userModel);
      }
    }

    if (context.mounted && currentPage() && session.isActive) {
      showModalBottomSheet(
        context: context,
        builder: (context) => SharePanel(
          sharing: sharing,
          content: content,
          userList: userList,
        ),
        useSafeArea: true,
        enableDrag: false,
        isScrollControlled: true,
      );
    }
  }

  static Future<void> pushDynFromId({
    String? id,
    Object? rid,
    bool off = false,
    Object? type,
  }) async {
    if (id == null && rid == null) {
      SmartDialog.showToast('动态缺少有效标识');
      return;
    }
    final request = NavigationRequest();
    try {
      request.showLoading();
      final res = await DynamicsHttp.dynamicDetail(
        id: id,
        rid: rid,
        type: rid != null ? 2 : null,
      );
      if (!request.isCurrent) return;
      if (res case Success(:final response)) {
        if (response.basic?.commentType == 12) {
          toDupNamed(
            '/articlePage',
            parameters: {
              'id': response.idStr.toString(),
              'type': 'opus',
            },
            off: off,
          );
        } else {
          toDupNamed('/dynamicDetail', arguments: {'item': response}, off: off);
        }
      } else {
        res.toast();
      }
    } catch (error, stackTrace) {
      logger.w('打开动态失败', error: error.runtimeType, stackTrace: stackTrace);
      if (request.isCurrent) SmartDialog.showToast('动态加载失败，请重试');
    } finally {
      await request.close();
    }
  }

  static void showFavBottomSheet({
    required BuildContext context,
    required FavMixin ctr,
  }) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxWidth: min(640, context.mediaQueryShortestSide),
      ),
      builder: (BuildContext context) {
        final maxChildSize =
            PlatformUtils.isMobile && !context.mediaQuerySize.isPortrait
            ? 1.0
            : 0.7;
        return DraggableScrollableSheet(
          minChildSize: 0,
          maxChildSize: 1,
          snap: true,
          expand: false,
          snapSizes: [maxChildSize],
          initialChildSize: maxChildSize,
          builder: (BuildContext context, ScrollController scrollController) {
            return FavPanel(
              ctr: ctr,
              scrollController: scrollController,
            );
          },
        );
      },
    );
  }

  static void reportVideo(int aid) {
    Get.toNamed(
      '/webview',
      parameters: {'url': 'https://www.bilibili.com/appeal/?avid=$aid'},
      arguments: const {'rewriteCopyrightReport': true},
    );
  }

  static bool _fitsInAndroidRequirements(int width, int height) {
    final aspectRatio = width / height;
    const min = 1 / 2.39;
    const max = 2.39;
    return (min <= aspectRatio) && (aspectRatio <= max);
  }

  static void enterPip({
    int? width,
    int? height,
    bool autoEnter = false,
    required bool isLive,
    required bool isPlaying,
  }) {
    if (width != null &&
        height != null &&
        !_fitsInAndroidRequirements(width, height)) {
      if (height > width) {
        width = 9;
        height = 16;
      } else {
        width = 16;
        height = 9;
      }
    }
    PiliAndroidHelper.enterPip(
      width ?? 16,
      height ?? 9,
      autoEnter: autoEnter,
      isLive: isLive,
      isPlaying: isPlaying,
    );
  }

  static Future<void> pushDynDetail(
    DynamicItemModel item, {
    bool isPush = false,
    bool viewComment = false,
  }) async {
    final request = NavigationRequest();
    try {
      await _pushDynDetailOwned(
        item,
        request: request,
        isPush: isPush,
        viewComment: viewComment,
      );
    } finally {
      await request.close();
    }
  }

  static Future<void> _pushDynDetailOwned(
    DynamicItemModel item, {
    required NavigationRequest request,
    bool isPush = false,
    bool viewComment = false,
  }) async {
    feedBack();

    void push() {
      if (item.basic?.commentType == 12) {
        toDupNamed(
          '/articlePage',
          parameters: {
            'id': item.idStr,
            'type': 'opus',
          },
        );
      } else {
        if (item.linkFolded) {
          pushDynFromId(id: item.idStr);
          return;
        }
        toDupNamed(
          '/dynamicDetail',
          arguments: {
            'item': item,
            if (viewComment) 'viewComment': true,
          },
        );
      }
    }

    /// 点击评论action 直接查看评论
    if (isPush) {
      push();
      return;
    }

    // if (kDebugMode) debugPrint('pushDynDetail: ${item.type}');

    switch (item.type) {
      case 'DYNAMIC_TYPE_AV':
        final archive = item.modules.moduleDynamic!.major!.archive!;
        // pgc
        if (archive.type == 2) {
          // jumpUrl
          if (archive.jumpUrl case final jumpUrl?) {
            if (viewPgcFromUri(jumpUrl)) {
              return;
            }
          }
          // redirectUrl from intro
          final res = await VideoHttp.videoIntro(bvid: archive.bvid!);
          if (!request.isCurrent) return;
          if (res.dataOrNull?.redirectUrl case final redirectUrl?) {
            if (viewPgcFromUri(redirectUrl)) {
              return;
            }
          }
          // redirectUrl from jumpUrl
          final redirectUrl = await UrlUtils.parseRedirectUrl(
            archive.jumpUrl.http2https,
            false,
          );
          if (!request.isCurrent) return;
          if (redirectUrl != null) {
            if (viewPgcFromUri(redirectUrl)) {
              return;
            }
          }
        }

        try {
          String bvid = archive.bvid!;
          String cover = archive.cover!;
          final result = await SearchHttp.pageWithDimension(bvid: bvid);
          if (!request.isCurrent) return;
          if (result is Error) {
            result.toast();
            return;
          }
          final res = result.dataOrNull;
          final cid = res?.cid;
          if (cid != null) {
            toVideoPage(
              bvid: bvid,
              cid: cid,
              cover: cover,
              dimension: res!.dimension,
              title: archive.title,
            );
          }
        } catch (error, stackTrace) {
          logger.w(
            '打开动态视频失败',
            error: error.runtimeType,
            stackTrace: stackTrace,
          );
          if (request.isCurrent) SmartDialog.showToast('视频获取失败，请重试');
        }
        break;

      /// 专栏文章查看
      case 'DYNAMIC_TYPE_ARTICLE':
        toDupNamed(
          '/articlePage',
          parameters: {
            'id': item.idStr,
            'type': 'opus',
          },
        );
        break;

      case 'DYNAMIC_TYPE_PGC':
        // if (kDebugMode) debugPrint('番剧');
        SmartDialog.showToast('暂未支持的类型，请联系开发者');
        break;

      case 'DYNAMIC_TYPE_LIVE':
        final liveRcmd = item.modules.moduleDynamic!.major!.live!;
        toLiveRoom(liveRcmd.id);
        break;

      case 'DYNAMIC_TYPE_LIVE_RCMD':
        final liveRcmd = item.modules.moduleDynamic!.major!.liveRcmd!;
        toLiveRoom(liveRcmd.roomId);
        break;

      case 'DYNAMIC_TYPE_SUBSCRIPTION_NEW':
        final live = item
            .modules
            .moduleDynamic!
            .major!
            .subscriptionNew!
            .liveRcmd!
            .content!
            .livePlayInfo!;
        toLiveRoom(live.roomId);
        break;

      /// 合集查看
      case 'DYNAMIC_TYPE_UGC_SEASON':
        final ugcSeason = item.modules.moduleDynamic!.major!.ugcSeason!;
        int aid = ugcSeason.aid!;
        String bvid = IdUtils.av2bv(aid);
        String cover = ugcSeason.cover!;
        final result = await SearchHttp.pageWithDimension(bvid: bvid);
        if (!request.isCurrent) return;
        if (result is Error) {
          result.toast();
          return;
        }
        final res = result.dataOrNull;
        final cid = res?.cid;
        if (cid != null) {
          toVideoPage(
            aid: aid,
            bvid: bvid,
            cid: cid,
            cover: cover,
            dimension: res!.dimension,
            title: ugcSeason.title,
          );
        }
        break;

      /// 番剧查看
      case 'DYNAMIC_TYPE_PGC_UNION':
        // if (kDebugMode) debugPrint('DYNAMIC_TYPE_PGC_UNION 番剧');
        final pgc = item.modules.moduleDynamic!.major!.pgc!;
        if (pgc.epid != null) {
          viewPgc(epId: pgc.epid);
        }
        break;

      case 'DYNAMIC_TYPE_MEDIALIST':
        if (item.modules.moduleDynamic?.major?.medialist
            case final medialist?) {
          final String? url = medialist.jumpUrl;
          if (url != null) {
            if (url.contains('medialist/detail/ml')) {
              Get.toNamed(
                '/favDetail',
                parameters: {
                  'heroTag': '${medialist.cover}',
                  'mediaId': '${medialist.id}',
                },
              );
            } else {
              handleWebview(url.http2https);
            }
          }
        }
        break;

      case 'DYNAMIC_TYPE_COURSES_SEASON':
        PageUtils.viewPugv(
          seasonId: item.modules.moduleDynamic!.major!.courses!.id,
        );
        break;

      default:
        push();
        break;
    }
  }

  static void inAppWebview(
    String url, {
    bool off = false,
  }) {
    if (Pref.openInBrowser) {
      launchURL(url);
    } else {
      Get.offOrToNamed(
        '/webview',
        parameters: {'url': url},
        arguments: const {'inApp': true},
        off: off,
      );
    }
  }

  static Future<void> launchURL(
    String url, {
    LaunchMode mode = LaunchMode.externalApplication,
  }) async {
    try {
      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: mode)) {
        SmartDialog.showToast('无法打开链接，请检查可用的浏览器或应用');
      }
    } catch (error, stackTrace) {
      logger.w('启动外部链接失败', error: error.runtimeType, stackTrace: stackTrace);
      SmartDialog.showToast('无法打开链接，请检查可用的浏览器或应用');
    }
  }

  static Future<void> handleWebview(
    String url, {
    bool inApp = false,
    Map? parameters,
  }) async {
    final route = Get.routing.route;
    if (!inApp && Pref.openInBrowser) {
      final handled = await PiliScheme.routePushFromUrl(url, selfHandle: true);
      if (!identical(Get.routing.route, route) || !(route?.isCurrent ?? true)) {
        return;
      }
      if (!handled) {
        await launchURL(url);
      }
    } else {
      await PiliScheme.routePushFromUrl(url, parameters: parameters);
    }
  }

  static Future<void>? showVideoBottomSheet(
    BuildContext context, {
    required Widget child,
    ValueGetter<EdgeInsets>? padding,
    double maxWidth = 500,
  }) {
    if (!context.mounted) {
      return null;
    }
    return Get.key.currentState!.push(
      PublishRoute(
        pageBuilder: (context, animation, secondaryAnimation) {
          final isPortrait = context.isPortrait;
          return SafeArea(
            // 竖屏面板背景铺到屏幕底边，内容在面板内部另行避让手势区。
            bottom: !isPortrait,
            child: CustomFractionallySizedBox(
              maxWidth: maxWidth,
              widthFactor: isPortrait ? 1.0 : 0.5,
              heightFactor: isPortrait ? 0.7 : 1.0,
              alignment: isPortrait ? .bottomCenter : .centerRight,
              child: Padding(
                padding: isPortrait ? padding?.call() ?? .zero : .zero,
                child: child,
              ),
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 350),
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          final begin = context.isPortrait
              ? const Offset(0.0, 1.0)
              : const Offset(1.0, 0.0);
          return SlideTransition(
            position: animation.drive(
              Tween<Offset>(
                begin: begin,
                end: Offset.zero,
              ).chain(CurveTween(curve: Curves.easeInOut)),
            ),
            child: child,
          );
        },
        settings: RouteSettings(arguments: Get.arguments),
      ),
    );
  }

  static void toLiveRoom(
    int? roomId, {
    bool off = false,
  }) {
    if (roomId == null) {
      return;
    }
    Get.offOrToNamed(
      '/liveRoom',
      arguments: roomId,
      off: off,
      preventDuplicates: off,
    );
  }

  /// 卡片缺少分 P 时由本次导航持有查询，回执只交付给原账号与来源。
  static Future<void> openVideo({
    required BuildContext context,
    Object? aid,
    String? bvid,
    int? cid,
    int? part,
    String? cover,
    String? title,
    int? progress,
    bool isVertical = false,
    Dimension? dimension,
    bool Function()? isCurrent,
    void Function(int cid)? onResolved,
  }) async {
    if (!context.mounted) return;
    final source = context.widget;
    final request = NavigationRequest();
    final account = Accounts.heartbeat;
    final mainAccount = Accounts.main;
    bool current() =>
        context.mounted &&
        identical(context.widget, source) &&
        request.isCurrent &&
        identical(account, Accounts.heartbeat) &&
        identical(mainAccount, Accounts.main) &&
        (isCurrent?.call() ?? true);
    try {
      if (!current()) return;
      final value = aid is int ? aid : int.tryParse(aid?.toString() ?? '');
      final parsedAid = value != null && value > 0 ? value : null;
      final targetBvid = bvid?.trim();
      if ((parsedAid == null || parsedAid <= 0) &&
          (targetBvid == null || targetBvid.isEmpty)) {
        SmartDialog.showToast('视频标识缺失，请刷新列表');
        return;
      }
      if (cid == null || cid <= 0) {
        request.showLoading('资源获取中');
        final result = await SearchHttp.pageWithDimension(
          account: account,
          aid: parsedAid,
          bvid: targetBvid,
          part: part,
        );
        await request.closeLoading();
        if (!current()) return;
        if (result is Error) {
          result.toast();
          return;
        }
        cid = result.dataOrNull?.cid;
        dimension ??= result.dataOrNull?.dimension;
      }
      if (!current()) return;
      if (cid == null || cid <= 0) {
        SmartDialog.showToast('该视频暂无可播放分 P');
        return;
      }
      if (onResolved != null) {
        onResolved(cid);
      } else {
        toVideoPage(
          aid: parsedAid,
          bvid: targetBvid?.isNotEmpty == true ? targetBvid : null,
          cid: cid,
          cover: cover,
          title: title,
          progress: progress,
          isVertical: isVertical,
          dimension: dimension,
        );
      }
    } catch (error, stackTrace) {
      logger.w('打开视频失败', error: error.runtimeType, stackTrace: stackTrace);
      if (current()) SmartDialog.showToast('视频获取失败，请重试');
    } finally {
      await request.close();
    }
  }

  static Future<void>? toVideoPage({
    VideoType videoType = VideoType.ugc,
    int? aid,
    String? bvid,
    required int cid,
    int? seasonId,
    int? epId,
    int? pgcType,
    String? cover,
    String? title,
    int? progress, // milliseconds
    Map? extraArguments,
    bool off = false,
    bool isVertical = false,
    Dimension? dimension,
  }) {
    final arguments = {
      'aid': aid ?? IdUtils.bv2av(bvid!),
      'bvid': bvid ?? IdUtils.av2bv(aid!),
      'cid': cid,
      'seasonId': ?seasonId,
      'epId': ?epId,
      'pgcType': ?pgcType,
      'cover': ?cover,
      'title': ?title,
      'progress': ?progress,
      'videoType': videoType,
      'isVertical': dimension?.isVertical ?? isVertical,
      'heroTag': Utils.makeHeroTag(cid),
      ...?extraArguments,
    };
    return PageUtils.toDupNamed('/videoV', arguments: arguments, off: off);
  }

  static final _pgcRegex = RegExp(r'(ep|ss)(\d+)');
  static bool viewPgcFromUri(
    String uri, {
    bool isPgc = true,
    int? progress, // milliseconds
    int? aid,
    bool off = false,
  }) {
    RegExpMatch? match = _pgcRegex.firstMatch(uri);
    if (match != null) {
      bool isSeason = match.group(1) == 'ss';
      String id = match.group(2)!;
      if (isPgc) {
        viewPgc(
          seasonId: isSeason ? id : null,
          epId: isSeason ? null : id,
          progress: progress,
          off: off,
        );
      } else {
        viewPugv(
          seasonId: isSeason ? id : null,
          epId: isSeason ? null : id,
          aid: aid,
          progress: progress,
          off: off,
        );
      }
      return true;
    }
    return false;
  }

  static EpisodeItem findEpisode(
    List<EpisodeItem> episodes, {
    dynamic epId,
    bool isPgc = true,
  }) {
    // epId episode -> progress episode -> first episode
    EpisodeItem? episode;
    if (epId != null) {
      epId = epId.toString();
      episode = episodes.firstWhereOrNull(
        (item) => (isPgc ? item.epId : item.id).toString() == epId,
      );
    }
    return episode ?? episodes.first;
  }

  static Future<void> viewPgc({
    dynamic seasonId,
    dynamic epId,
    int? progress, // milliseconds
    bool off = false,
  }) async {
    final request = NavigationRequest();
    try {
      request.showLoading('资源获取中');
      final res = await SearchHttp.pgcInfo(seasonId: seasonId, epId: epId);
      if (!request.isCurrent) return;
      if (res case Success(:final response)) {
        final episodes = response.episodes;
        final hasEpisode = episodes != null && episodes.isNotEmpty;

        EpisodeItem? episode;

        void viewSection(EpisodeItem episode) {
          toVideoPage(
            videoType: VideoType.ugc,
            bvid: episode.bvid!,
            cid: episode.cid!,
            seasonId: response.seasonId,
            epId: episode.epId,
            cover: episode.cover,
            title: episode.title,
            progress: progress,
            extraArguments: {
              'pgcApi': true,
              'pgcItem': response,
            },
            off: off,
          );
        }

        if (epId != null) {
          epId = epId.toString();
          if (hasEpisode) {
            episode = episodes.firstWhereOrNull(
              (item) => item.epId.toString() == epId,
            );
          }

          // find section
          if (episode == null) {
            final sections = response.section;
            if (sections != null && sections.isNotEmpty) {
              for (final section in sections) {
                final episodes = section.episodes;
                if (episodes != null && episodes.isNotEmpty) {
                  for (final episode in episodes) {
                    if (episode.epId.toString() == epId) {
                      // view as ugc
                      viewSection(episode);
                      return;
                    }
                  }
                }
              }
            }
          }
        }

        if (hasEpisode) {
          episode ??= findEpisode(
            episodes,
            epId: response.userStatus?.progress?.lastEpId,
          );
          toVideoPage(
            videoType: VideoType.pgc,
            bvid: episode.bvid!,
            cid: episode.cid!,
            seasonId: response.seasonId,
            epId: episode.epId,
            pgcType: response.type,
            cover: episode.cover,
            progress: progress,
            extraArguments: {
              'pgcItem': response,
            },
            off: off,
          );
          return;
        } else {
          episode ??= response.section?.firstOrNull?.episodes?.firstOrNull;
          if (episode != null) {
            viewSection(episode);
            return;
          }
        }

        SmartDialog.showToast('资源加载失败');
      } else {
        res.toast();
      }
    } catch (e, stackTrace) {
      if (request.isCurrent) SmartDialog.showToast('资源加载失败，请重试');
      logger.w('加载番剧资源失败', error: e.runtimeType, stackTrace: stackTrace);
    } finally {
      await request.close();
    }
  }

  static Future<void> viewPugv({
    dynamic seasonId,
    dynamic epId,
    int? aid,
    int? progress, // milliseconds
    bool off = false,
  }) async {
    final request = NavigationRequest();
    try {
      request.showLoading('资源获取中');
      final res = await SearchHttp.pugvInfo(seasonId: seasonId, epId: epId);
      if (!request.isCurrent) return;
      if (res case Success(:final response)) {
        final episodes = response.episodes;
        if (episodes != null && episodes.isNotEmpty) {
          EpisodeItem? episode;
          if (aid != null) {
            episode = episodes.firstWhereOrNull((e) => e.aid == aid);
          }
          episode ??= findEpisode(
            episodes,
            epId: epId ?? response.userStatus?.progress?.lastEpId,
            isPgc: false,
          );
          toVideoPage(
            videoType: VideoType.pugv,
            aid: episode.aid!,
            cid: episode.cid!,
            seasonId: response.seasonId,
            epId: episode.id,
            cover: episode.cover,
            progress: progress,
            extraArguments: {
              'pgcItem': response,
            },
            off: off,
          );
        } else {
          SmartDialog.showToast('资源加载失败');
        }
      } else {
        res.toast();
      }
    } catch (error, stackTrace) {
      logger.w('加载课程资源失败', error: error.runtimeType, stackTrace: stackTrace);
      if (request.isCurrent) SmartDialog.showToast('资源加载失败，请重试');
    } finally {
      await request.close();
    }
  }

  @pragma('vm:prefer-inline')
  static Future<T?>? toDupNamed<T>(
    String page, {
    dynamic arguments,
    Map<String, String>? parameters,
    bool off = false,
  }) => Get.offOrToNamed(
    page,
    arguments: arguments,
    parameters: parameters,
    preventDuplicates: false,
    off: off,
  );
}
